require "timeout"

module ProcessBarrier
  # Kill a real independent worker at extractor entry, after its admission
  # transaction has committed. A pipe barrier, rather than timing, selects
  # the exact crash boundary.
  def crash_at_extraction(&work)
    crash_at_boundary(work:) do |reached, hold|
      SourceImports::TextExtractor.define_singleton_method(:call) do |**|
        reached.write("r")
        hold.read(1)
      end
    end
  end

  def crash_at_storage(after_write:, &work)
    crash_at_boundary(work:) do |reached, hold|
      original = ActiveStorage::Blob.service.method(:upload)
      ActiveStorage::Blob.service.define_singleton_method(:upload) do |*arguments, **options|
        original.call(*arguments, **options) if after_write
        reached.write("r")
        hold.read(1)
      end
    end
  end

  def crash_at_storage_delete(after_delete:, &work)
    crash_at_boundary(work:) do |reached, hold|
      original = ActiveStorage::Blob.service.method(:delete)
      ActiveStorage::Blob.service.define_singleton_method(:delete) do |*arguments|
        original.call(*arguments) if after_delete
        reached.write("r")
        hold.read(1)
      end
    end
  end

  def crash_at_boundary(work:)
    ActiveRecord::Base.connection_handler.clear_all_connections!
    reached_read, reached_write = IO.pipe
    hold_read, hold_write = IO.pipe
    pid = fork do
      reached_read.close
      hold_write.close
      yield reached_write, hold_read
      work.call
      exit! 1
    end
    reached_write.close
    hold_read.close
    Timeout.timeout(15) { raise "worker missed extraction barrier" unless reached_read.read(1) == "r" }
    Process.kill("KILL", pid)
    Process.wait(pid)
    pid = nil
  ensure
    if pid
      Process.kill("KILL", pid) rescue nil
      Process.wait(pid) rescue nil
    end
    [ reached_read, reached_write, hold_read, hold_write ].compact.each { |pipe| pipe.close unless pipe.closed? }
  end
  private :crash_at_boundary

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

  # The pipe proves the independent PostgreSQL session owns the lock before
  # cleanup runs. Releasing it is explicit; no timing assumptions or sleeps.
  def with_process_lock(sql)
    ActiveRecord::Base.connection_handler.clear_all_connections!
    ready_read, ready_write = IO.pipe
    release_read, release_write = IO.pipe
    pid = fork do
      ready_read.close
      release_write.close
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute(sql)
        ready_write.write("r")
        release_read.read(1)
      end
      exit! 0
    end
    ready_write.close
    release_read.close
    Timeout.timeout(15) { assert_equal "r", ready_read.read(1) }
    yield
  ensure
    release_write&.write("g") unless release_write&.closed?
    Process.wait(pid) if pid
    [ ready_read, ready_write, release_read, release_write ].compact.each { |pipe| pipe.close unless pipe.closed? }
  end
end
