module Syskit
    module NetworkGeneration
        # Extension to the logger's task model for logging configuration
        #
        # It is automatically included in Engine#configure_logging
        module LoggerConfigurationSupport
            attr_reader :logged_ports

            # True if this logger is its deployment's default logger
            #
            # In this case, it will set itself up using the deployment's logging
            # configuration
            attr_predicate :default_logger?, true

            def initialize(arguments = Hash.new)
                super
                @logged_ports = Set.new
            end

            # Wrapper on top of the createLoggingPort operation
            #
            # +sink_port_name+ is the port name of the logging task,
            # +logged_task+ the Syskit::TaskContext object from
            # which the data is being logged and +logged_port+ the
            # Orocos::Spec::OutputPort model object of the port that we want to
            # log.
            def createLoggingPort(sink_port_name, logged_task, logged_port)
                return if logged_ports.include?([sink_port_name, logged_port.type.name])

                logged_port_type = logged_port.orocos_type_name

                metadata = Hash[
                    'rock_task_model' => logged_task.model.orogen_model.name,
                    'rock_task_name' => logged_task.orocos_name,
                    'rock_task_object_name' => logged_port.name,
                    'rock_stream_type' => 'port']
                metadata = metadata.map do |k, v|
                    Hash['key' => k, 'value' => v]
                end

                @create_port ||= operation('createLoggingPort')
                if !@create_port.callop(sink_port_name, logged_port_type, metadata)
                    # Look whether a port with that name and type already
                    # exists. If it is the case, it means somebody else already
                    # created it and we're fine- Otherwise, raise an error
                    begin
                        port = input_port(sink_port_name)
                        if port.orocos_type_name != logged_port_type
                            raise ArgumentError, "cannot create a logger port of name #{sink_port_name} and type #{logged_port_type}: a port of same name but of type #{port.orocos_type_name} exists"
                        end
                    rescue Orocos::NotFound
                        raise ArgumentError, "cannot create a logger port of name #{sink_port_name} and type #{logged_port_type}"
                    end
                end
                logged_ports << [sink_port_name, logged_port_type]
            end

            def configure
                super

                if default_logger?
                    deployment = execution_agent
                    if !deployment.arguments[:log] ||
                        Roby::State.orocos.deployment_excluded_from_log?(deployment)
                        Robot.info "not automatically logging any port in deployment #{name}"
                    else
                        # Only setup the logger
                        deployment.orogen_model.setup_logger(
                            :log_dir => deployment.log_dir,
                            :remote => (deployment.machine != 'localhost'))
                    end
                end

                each_input_connection do |source_task, source_port_name, sink_port_name, policy|
                    source_port = source_task.find_output_port_model(source_port_name)
                    createLoggingPort(sink_port_name, source_task, source_port)
                end
            end

            # Configures each running deployment's logger, based on the
            # information in +port_dynamics+
            #
            # The "configuration" means that we create the necessary connections
            # between each component's port and the logger
            def self.add_logging_to_network(engine)
                Logger::Logger.include LoggerConfigurationSupport

                engine.deployment_tasks.each do |deployment|
                    next if !deployment.plan

                    logger_task = nil
                    logger_task_name = "#{deployment.deployment_name}_Logger"

                    required_logging_ports = Array.new
                    required_connections   = Array.new
                    deployment.each_executed_task do |t|
                        if t.finishing? || t.finished?
                            next
                        end

                        if !logger_task && t.orocos_name == logger_task_name
                            logger_task = t
                            next
                        elsif t.model.name == "Syskit::Logger::Logger"
                            next
                        end

                        connections = Hash.new

                        all_ports = []

                        t.model.each_output_port do |p|
                            all_ports << [p.name, p]
                        end
                        t.instanciated_dynamic_outputs.each do |port_name, port_model|
                            all_ports << [port_name, port_model]
                        end

                        all_ports.each do |port_name, p|
                            next if !deployment.log_port?(p)

                            log_port_name = "#{t.orocos_name}.#{port_name}"
                            connections[[port_name, log_port_name]] = { :fallback_policy => { :type => :buffer, :size => Engine.default_logging_buffer_size } }
                            required_logging_ports << [log_port_name, t, p]
                        end
                        required_connections << [t, connections]
                    end

                    if required_connections.empty?
                        if logger_task
                            # Keep loggers alive even if not needed
                            plan.add_mission(logger_task)
                        end
                        next 
                    end

                    logger_task ||=
                        begin
                            deployment.task(logger_task_name)
                        rescue ArgumentError
                            Engine.warn "deployment #{deployment.deployment_name} has no logger (#{logger_task_name})"
                            next
                        end
                    engine.plan.add_permanent(logger_task)
                    logger_task.default_logger = true
                    # Make sure that the tasks are started after the logger was
                    # started
                    deployment.each_executed_task do |t|
                        if t.pending?
                            t.should_start_after logger_task.start_event
                        end
                    end

                    if logger_task.setup?
                        # The logger task is already configured. Add the ports
                        # manually
                        #
                        # Otherwise, Logger#configure will take care of it for
                        # us
                        required_logging_ports.each do |port_name, logged_task, logged_port|
                            logger_task.createLoggingPort(port_name, logged_task, logged_port)
                        end
                    end
                    required_connections.each do |task, connections|
                        connections = connections.map_value do |(port_name, log_port_name), policy|
                            out_port = task.find_output_port_model(port_name)

                            if !logger_task.find_input_port_model(log_port_name)
                                logger_task.instanciate_dynamic_input(log_port_name, out_port.type)
                            end
                            dataflow_dynamics.policy_for(task, port_name, log_port_name, logger_task, policy)
                        end

                        task.connect_ports(logger_task, connections)
                    end
                end

                # Finally, select 'default' as configuration for all
                # remaining tasks that do not have a 'conf' argument set
                engine.plan.find_local_tasks(Syskit::Logger::Logger).
                    each do |task|
                        if !task.arguments[:conf]
                            task.arguments[:conf] = ['default']
                        end
                    end

                # Mark as permanent any currently running logger
                engine.plan.find_tasks(Syskit::Logger::Logger).
                    not_finished.
                    each do |t|
                        plan.add_permanent(t)
                    end
            end
        end
        Engine.register_final_network_postprocessing(
            &LoggerConfigurationSupport.method(&:add_logging_to_network))
    end
end

