module Syskit
    module Runtime
        # Connection management at runtime
        class ConnectionManagement
            extend Logger::Hierarchy
            include Logger::Hierarchy

            attr_reader :plan

            attr_predicate :dry_run?, true

            def initialize(plan)
                @plan = plan
            end

            def self.update(plan, dry_run = false)
                manager = ConnectionManagement.new(plan)
                manager.dry_run = dry_run
                manager.update
            end

            # Updates an intermediate graph (Syskit::RequiredDataFlow) where
            # we store the concrete connections. We don't try to be smart:
            # remove all tasks that have to be updated and add their connections
            # again
            def update_required_dataflow_graph(tasks)
                seen = ValueSet.new

                # Remove first all tasks. Otherwise, removing some tasks will
                # also remove the new edges we just added
                for t in tasks
                    RequiredDataFlow.remove(t)
                end

                # Create the new connections
                for t in tasks
                    t.each_concrete_input_connection do |source_task, source_port, sink_port, policy|
                        next if seen.include?(source_task)
                        RequiredDataFlow.add_connections(source_task, t, [source_port, sink_port] => policy)
                    end
                    t.each_concrete_output_connection do |source_port, sink_port, sink_task, policy|
                        next if seen.include?(sink_task)
                        RequiredDataFlow.add_connections(t, sink_task, [source_port, sink_port] => policy)
                    end
                    seen << t
                end
            end

            # Computes the connection changes that are required to make the
            # required connections (declared in the DataFlow relation) match the
            # actual ones (on the underlying modules)
            #
            # It returns nil if the change can't be computed because the Roby
            # tasks are not tied to an underlying RTT task context.
            #
            # Returns [new, removed] where
            #
            #   new = { [from_task, to_task] => { [from_port, to_port] => policy, ... }, ... }
            #
            # in which +from_task+ and +to_task+ are instances of
            # Syskit::TaskContext (i.e. Roby tasks), +from_port+ and
            # +to_port+ are the port names (i.e. strings) and policy the policy
            # hash that Orocos::OutputPort#connect_to expects.
            #
            #   removed = { [from_task, to_task] => { [from_port, to_port], ... }, ... }
            #
            # in which +from_task+ and +to_task+ are instances of
            # Orocos::TaskContext (i.e. the underlying RTT tasks). +from_port+ and
            # +to_port+ are the names of the ports that have to be disconnected
            # (i.e. strings)
            def compute_connection_changes(tasks)
                if dry_run?
                    return [], []
                end

                not_running = tasks.find_all { |t| !t.orocos_task }
                if !not_running.empty?
                    debug do
                        debug "not computing connections because the deployment of the following tasks is not yet ready"
                        tasks.each do |t|
                            debug "  #{t}"
                        end
                        break
                    end
                    return
                end

                update_required_dataflow_graph(tasks)
                new_edges, removed_edges, updated_edges =
                    RequiredDataFlow.difference(ActualDataFlow, tasks, &:orocos_task)

                new = Hash.new
                new_edges.each do |source_task, sink_task|
                    new[[source_task, sink_task]] = source_task[sink_task, RequiredDataFlow]
                end

                removed = Hash.new
                removed_edges.each do |source_task, sink_task|
                    removed[[source_task, sink_task]] = source_task[sink_task, ActualDataFlow].keys.to_set
                end

                # We have to work on +updated+. The graphs are between tasks,
                # not between ports because of how ports are handled on both the
                # orocos.rb and Roby sides. So we must convert the updated
                # mappings into add/remove pairs. Moreover, to update a
                # connection policy we need to disconnect and reconnect anyway.
                #
                # Note that it is fine from a performance point of view, as in
                # most cases one removes all connections from two components to
                # recreate other ones between other components
                updated_edges.each do |source_task, sink_task|
                    new_mapping = source_task[sink_task, RequiredDataFlow]
                    old_mapping = source_task.orocos_task[sink_task.orocos_task, ActualDataFlow]

                    new_connections     = Hash.new
                    removed_connections = Set.new
                    new_mapping.each do |ports, new_policy|
                        if old_policy = old_mapping[ports]
                            if old_policy != new_policy
                                new_connections[ports] = new_policy
                                removed_connections << ports
                            end
                        else
                            new_connections[ports] = new_policy
                        end
                    end

                    if !new_connections.empty?
                        new[[source_task, sink_task]] = new_connections
                    end
                    if !removed_connections.empty?
                        removed[[source_task.orocos_task, sink_task.orocos_task]] = removed_connections
                    end
                end

                return new, removed
            end

            # Given a connection list, finds out which tasks will need to be
            # restarted for some of these connections to be applied.
            def update_restart_set(set, connections)
                connections.each do |(out_task, in_task), mappings|
                    if out_task.running? && !set.include?(out_task)
                        mappings.each_key do |out_port_name, in_port_name|
                            if out_task.model.find_output_port(out_port_name).static?
                                set << out_task
                                break
                            end
                        end
                    end

                    if in_task.running? && !set.include?(in_task)
                        mappings.each_key do |out_port_name, in_port_name|
                            if in_task.model.find_input_port(in_port_name).static?
                                set << in_task
                                break
                            end
                        end
                    end
                end

                set
            end

            # Specialized version of {partition_connections} for the set of new
            # connections. In addition to the criteria applied by
            # #partition_connections, it delays creating new connections towards
            # dynamic ports on tasks that are not yet configured (as #configure
            # is supposed to create the ports)
            def partition_new_connections(connections)
                partition_connections(connections) do |out_port, in_port, policy|
                    (out_port.dynamic? && !out_task.setup?) ||
                        (in_port.dynamic? && !in_task.setup?)
                end
            end

            # Partition connections between a set of connections that can be
            # modified right away, a set that will need to be applied later and
            # a set that can only be applied atomically, i.e. all at once when
            # all the other connections also have been applied.
            #
            # Each connection set is represented as an array of ((output_task,
            # input_task), mappings) tuples where +mappings+ maps
            # (output_port_name, input_port_name) to the desired connection
            # policy. This format is referred as ConnectionList in the rest of
            # this documentation.
            #
            # This is a partition function that is common to connection removal
            # and additions. It uses the following criteria:
            #
            # A connection can be applied right away if:
            #  - they involve at least one stopped task
            # A connection must be delayed if:
            #  - it involves a port that requires restarting the task, and the
            #    task is running
            # All other connections land in the atomic set
            #
            # @yieldparam [(OutputPort,InputPort,Hash)] a connection
            #   specification
            # @yieldreturn true if the connection needs to be delayed, false
            #   otherwise
            # @param [ConnectionList] connections the connection list to
            #   partition
            # @return [(ConnectionList,ConnectionList,ConnectionList)] the
            #   partitioned sets
            def partition_connections(connections)
                incremental, delayed, global = [], [], []
                connections.each do |tasks, mappings|
                    incremental_mappings, delayed_mappings, global_mappings = Hash.new, Hash.new, Hash.new
                    mappings.each do |port_names, policy|
                        out_port = tasks[0].model.find_output_port(port_names[0])
                        in_port  = tasks[1].model.find_input_port(port_names[1])

                        if block_given? && yield(out_port, in_port, policy)
                            delayed_mappings[port_names] = policy
                        elsif in_port.static? && in_task.running?
                            delayed_mappings[port_names] = policy
                        elsif !out_task.running? || !in_task.running?
                            incremental_mappings[port_names] = policy
                        else
                            global_mappings[port_names] = policy
                        end
                    end
                    incremental << [tasks, incremental_mappings] if !incremental_mappings.empty?
                    delayed     << [tasks, delayed_mappings]     if !delayed_mappings.empty?
                    global      << [tasks, global_mappings]      if !global_mappings.empty?
                end
                return incremental, delayed, global
            end

            def handle_connections_requiring_restart(delayed_new, delayed_removed)
                needs_restart = ValueSet.new
                update_restart_set(needs_restart, delayed_new)
                restart_orocos_tasks = ValueSet.new
                update_restart_set(restart_orocos_tasks, delayed_removed)
                restart_orocos_tasks.each do |orocos_task|
                    klass = TaskContext.model_for(orocos_task.model)
                    task = plan.find_tasks(klass).running.
                        find { |t| t.orocos_name == orocos_task.name }
                    if task
                        needs_restart << task
                    end
                end
                needs_restart -= restarting_tasks

                if !restart_tasks.empty?
                    new_tasks = Array.new
                    all_stopped = Roby::AndGenerator.new

                    restart_tasks.each do |task|
                        debug { "restarting #{task}" }
                        replacement = plan.recreate(task)
                        debug { "  replaced by #{replacement}" }
                        new_tasks << replacement
                        all_stopped << task.stop_event
                    end
                    new_tasks.each do |new_task|
                        all_stopped.add_causal_link new_task.start_event
                    end
                    throw :cancelled, all_stopped
                end

                restarting_tasks | needs_restart
            end

            # Apply all connection changes on the system. The principle is to
            # use a transaction-based approach: i.e. either we apply everything
            # or nothing.
            #
            # See #compute_connection_changes for the format of +new+ and
            # +removed+
            #
            # Returns a false value if it could not apply the changes and a true
            # value otherwise.
            def apply_connection_changes(new, removed, restarting_tasks)
                restart_tasks = ValueSet.new

                # Partition the connections between the ones we can apply and
                # the one that we need to delay
                new, delayed_new, atomic_new = partition_new_connections(new)
                removed, delayed_removed, atomic_removed = partition_connections(removed)

                # Find out which tasks must be restarted. If we already are
                # restarting the task, no new connections are going towards it,
                # they would go towards the new task.
                restarting_tasks = handle_connections_requiring_restart(delayed_new, delayed_removed, restarting_tasks)


                # Remove connections first
                removed.each do |(source_task, sink_task), mappings|
                    mappings.each do |source_port, sink_port|
                        debug do
                            debug "disconnecting #{source_task}:#{source_port}"
                            debug "     => #{sink_task}:#{sink_port}"
                            break
                        end

                        source = source_task.port(source_port, false)
                        sink   = sink_task.port(sink_port, false)

                        begin
                            if !source.disconnect_from(sink)
                                warn "while disconnecting #{source_task}:#{source_port} => #{sink_task}:#{sink_port} returned false"
                                warn "I assume that the ports are disconnected, but this should not have happened"
                            end

                        rescue Orocos::NotFound => e
                            warn "error while disconnecting #{source_task}:#{source_port} => #{sink_task}:#{sink_port}: #{e.message}"
                            warn "I am assuming that the disconnection is actually effective, since one port does not exist anymore"
                        rescue Orocos::ComError => e
                            warn "Communication error while disconnecting #{source_task}:#{source_port} => #{sink_task}:#{sink_port}: #{e.message}"
                            warn "I am assuming that the source component is dead and that therefore the connection is actually effective"
                        end

                        ActualDataFlow.remove_connections(source_task, sink_task,
                                          [[source_port, sink_port]])

                        # The following test is meant to make sure that we
                        # cleanup input ports after crashes. CORBA connections
                        # will properly cleanup the output port-to-corba part
                        # automatically, but never the corba-to-input port
                        #
                        # It will break code that connects to input ports
                        # externally. This is not a common case however.
                        # begin
                        #     if !ActualDataFlow.has_in_connections?(sink_task, sink_port)
                        #         debug { "calling #disconnect_all on the input port #{sink_task.name}:#{sink_port} since it has no input connections anymore" }
                        #         sink.disconnect_all
                        #     end
                        # rescue Orocos::NotFound
                        # rescue CORBA::ComError
                        # end
                    end
                end

                # And create the new ones
                pending_tasks = ValueSet.new
                new.each do |(from_task, to_task), mappings|
                    # The task might have been killed while the connections
                    # were already added to the data flow graph. Roby's GC will
                    # deal with that. Ignore.
                    next if !from_task.orocos_task
                    next if !to_task.orocos_task

                    mappings.each do |(from_port, to_port), policy|
                        debug do
                            debug "connecting #{from_task}:#{from_port}"
                            debug "     => #{to_task}:#{to_port}"
                            debug "     with policy #{policy}"
                            break
                        end

                        begin
                            policy, _ = Kernel.filter_options(policy, Orocos::Port::CONNECTION_POLICY_OPTIONS)
                            from_task.orocos_task.port(from_port).connect_to(to_task.orocos_task.port(to_port), policy)
                            ActualDataFlow.add_connections(from_task.orocos_task, to_task.orocos_task,
                                                       [from_port, to_port] => policy)
                        rescue Orocos::ComError
                            # The task will be aborted. Simply ignore
                        rescue Orocos::InterfaceObjectNotFound => e
                            if e.task == from_task.orocos_task && e.name == from_port
                                plan.engine.add_error(PortNotFound.new(from_task, from_port, :output))
                            else
                                plan.engine.add_error(PortNotFound.new(to_task, to_port, :input))
                            end

                        end
                    end
                    if !to_task.executable?
                        pending_tasks << to_task
                    end
                end

                # Tasks' executable flag is forcefully set to false until (1)
                # they are configured and (2) all static inputs are connected
                #
                # Check tasks for which we created an input. If they are not
                # executable and all_inputs_connected? returns true, set their
                # executable flag to nil
                debug do
                    debug "#{pending_tasks.size} pending tasks"
                    pending_tasks.each do |t|
                        debug "  #{t}: all_inputs_connected=#{t.all_inputs_connected?} executable=#{t.executable?}"
                    end
                    break
                end

                pending_tasks.each do |t|
                    if t.all_inputs_connected?
                        t.executable = nil
                        debug { "#{t} has all its inputs connected, set executable to nil and executable? = #{t.executable?}" }
                    end
                end

                true
            end

            def update
                tasks = Flows::DataFlow.modified_tasks

                tasks.delete_if do |t|
                    t.finished?
                end

                # The modifications to +tasks+ might have removed all input
                # connection. Make sure that in this case, executable? has been
                # reset to nil
                #
                # The normal workflow does not work in this case, as it is only
                # looking for tasks whose input connections have been modified
                tasks.each do |t|
                    if t.setup? && !t.executable? && t.plan == plan && t.all_inputs_connected?
                        t.executable = nil
                    end
                end

                if !tasks.empty?
                    # If there are some tasks that have been GCed/killed, we still
                    # need to update the connection graph to remove the old
                    # connections.  However, we should remove these tasks now as they
                    # should not be passed to compute_connection_changes
                    main_tasks, proxy_tasks = tasks.partition { |t| t.plan == plan }
                    main_tasks = main_tasks.to_value_set
                    if Flows::DataFlow.pending_changes
                        main_tasks.merge(Flows::DataFlow.pending_changes.first)
                    end

                    main_tasks.delete_if { |t| !t.plan || !t.execution_agent || t.execution_agent.ready_to_die? || t.execution_agent.finished? }
                    proxy_tasks.delete_if { |t| !t.plan }

                    debug do
                        debug "computing data flow update from modified tasks"
                        for t in main_tasks
                            debug "  #{t}"
                        end
                        break
                    end

                    new, removed = compute_connection_changes(main_tasks)
                    if new
                        debug do
                            debug "  new connections:"
                            new.each do |(from_task, to_task), mappings|
                                debug "    #{from_task} (#{from_task.running? ? 'running' : 'stopped'}) =>"
                                debug "       #{to_task} (#{to_task.running? ? 'running' : 'stopped'})"
                                mappings.each do |(from_port, to_port), policy|
                                    debug "      #{from_port}:#{to_port} #{policy}"
                                end
                            end
                            debug "  removed connections:"
                            debug "  disable debug display because it is unstable in case of process crashes"
                            #removed.each do |(from_task, to_task), mappings|
                            #    Engine.info "    #{from_task} (#{from_task.running? ? 'running' : 'stopped'}) =>"
                            #    Engine.info "       #{to_task} (#{to_task.running? ? 'running' : 'stopped'})"
                            #    mappings.each do |from_port, to_port|
                            #        Engine.info "      #{from_port}:#{to_port}"
                            #    end
                            #end
                                
                            break
                        end

                        pending_replacement =
                            if Flows::DataFlow.pending_changes
                                Flows::DataFlow.pending_changes[3]
                            end

                        Flows::DataFlow.pending_changes = [main_tasks, new, removed, pending_replacement]
                        Flows::DataFlow.modified_tasks.clear
                        Flows::DataFlow.modified_tasks.merge(proxy_tasks.to_value_set)
                    else
                        debug "cannot compute changes, keeping the tasks queued"
                    end
                end

                if Flows::DataFlow.pending_changes
                    _, new, removed, pending_replacement = Flows::DataFlow.pending_changes
                    if pending_replacement && !pending_replacement.happened? && !pending_replacement.unreachable?
                        debug "waiting for replaced tasks to stop"
                    else
                        if pending_replacement
                            debug "successfully started replaced tasks, now applying pending changes"
                            pending_replacement.clear_vertex
                            plan.unmark_permanent(pending_replacement)
                        end

                        pending_replacement = catch :cancelled do
                            debug "applying pending changes from the data flow graph"
                            apply_connection_changes(new, removed)
                            Flows::DataFlow.pending_changes = nil
                        end

                        if !Flows::DataFlow.pending_changes
                            debug "successfully applied pending changes"
                        elsif pending_replacement
                            debug "waiting for replaced tasks to stop"
                            plan.add_permanent(pending_replacement)
                            Flows::DataFlow.pending_changes[3] = pending_replacement
                        else
                            debug "failed to apply pending changes"
                        end
                    end
                end
            end
        end
    end
end

