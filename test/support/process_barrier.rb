require "timeout"

module ProcessBarrier
  # Every child starts on its own PostgreSQL connection after all children
  # have reached the pipe barrier. No sleeps or inherited database sessions.
  def in_processes(count, &work)
    ActiveRecord::Base.connection_handler.clear_all_connections!
    children = count.times.map do |index|
      ready_read, ready_write = IO.pipe
      start_read, start_write = IO.pipe
      result_read, result_write = IO.pipe
      pid = fork do
        ready_read.close
        start_write.close
        result_read.close
        begin
          ActiveRecord::Base.connection.select_value("SELECT 1")
          ready_write.write("r")
          ready_write.close
          start_read.read(1)
          Marshal.dump({ value: work.call(index) }, result_write)
        rescue StandardError => error
          Marshal.dump({ error: "#{error.class}: #{error.message}" }, result_write)
        ensure
          result_write.close
          exit! 0
        end
      end
      ready_write.close
      start_read.close
      result_write.close
      [ pid, ready_read, start_write, result_read ]
    end
    Timeout.timeout(30) do
      children.each { |_, ready, _, _| raise "child failed before barrier" unless ready.read(1) == "r" }
      children.each { |_, _, start, _| start.write("g"); start.close }
      children.map do |pid, _, _, result|
        payload = Marshal.load(result)
        Process.wait(pid)
        raise payload[:error] if payload[:error]

        payload.fetch(:value)
      end
    end
  ensure
    children&.each do |pid, *pipes|
      pipes.each { |pipe| pipe.close unless pipe.closed? }
      begin
        Process.kill("KILL", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end
end
