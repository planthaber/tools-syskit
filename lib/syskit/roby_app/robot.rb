module Syskit
    module RobyApp
        # Extensions to Roby's main Robot object
        module Robot
            def each_device(&block)
                Roby.app.orocos_engine.robot.devices.each_value(&block)
            end

            def devices(&block)
                if block
                    Kernel.dsl_exec(Roby.app.orocos_engine.robot, Syskit.constant_search_path, !Roby.app.filter_backtraces?, &block)
                    Roby.app.orocos_engine.export_devices_to_planner(::MainPlanner)
                else
                    each_device
                end
            end
        end
    end
end

