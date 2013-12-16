# encoding: utf-8
module Flaky
  module Color
    def cyan str
      "\e[36m#{str}\e[0m"
    end

    def red str
      "\e[31m#{str}\e[0m"
    end

    def green str
      "\e[32m#{str}\e[0m"
    end
  end

  class LogArtifact
    def initialize opts={}
      @result_dir = opts.fetch :result_dir, ''
      @pass_str   = opts.fetch :pass_str, ''
      @test_name = opts.fetch :test_name, ''
    end

    def name str
      file_name = File.basename(str)

      str = str[0..-1-file_name.length].gsub('/', '_')
      str = str + '_' if str[-1] != '_'
      str += @test_name.split('/').last

      File.join @result_dir, @pass_str, str, file_name
    end
  end

  class Run
    include Flaky::Color
    attr_reader :tests, :result_dir, :result_file

    def initialize
      @tests = {}
      @start_time = Time.now

      result_dir = '/tmp/flaky/'
      # rm -rf result_dir
      FileUtils.rm_rf result_dir
      FileUtils.mkdir_p result_dir

      @result_dir = result_dir
      @result_file = File.join result_dir, 'result.txt'
    end

    def report opts={}
      save_file = opts.fetch :save_file, true
      puts "\n" * 2
      success = ''
      failure = ''
      total_success = 0
      total_failure = 0
      @tests.each do |name, stats|
        runs = stats[:runs]
        pass = stats[:pass]
        fail = stats[:fail]
        line = "#{name}, runs: #{runs}, pass: #{pass}," +
            " fail: #{fail}\n"
        if fail > 0 && pass <= 0
          failure += line
          total_failure += 1
        else
          success += line
          total_success += 1
        end
      end

      out = "#{total_success + total_failure} Tests\n\n"
      out += "Failure (#{total_failure}):\n#{failure}\n" unless failure.empty?
      out += "Success (#{total_success}):\n#{success}" unless success.empty?

      duration = Time.now - @start_time
      duration = ChronicDuration.output(duration.round) || '0s'
      out += "\nFinished in #{duration}"

      # overwrite file
      File.open(@result_file, 'w') do |f|
        f.puts out
      end if save_file

      puts out
    end

    def _execute run_cmd, test_name, runs, appium, sauce
      # must capture exit code or log is an array.
      log, exit_code = Open3.capture2e run_cmd

      result = /\d+ runs, \d+ assertions, \d+ failures, \d+ errors, \d+ skips/
      success = /0 failures, 0 errors, 0 skips/
      passed = true

      found_results = log.scan result
      # all result instances must match success
      found_results.each do |result|
        # runs must be >= 1. 0 runs mean no tests were run.
        r_count = result.match /(\d+) runs/
        runs_not_zero = r_count && r_count[1] && r_count[1].to_i > 0 ? true : false

        unless result.match(success) && runs_not_zero
          passed = false
          break
        end
      end

      # no results found.
      passed = false if found_results.length <= 0
      pass_str = passed ? 'pass' : 'fail'
      test = @tests[test_name]
      # save log
      if passed
        pass = test[:pass] += 1
        postfix = "pass_#{pass}"
      else
        fail = test[:fail] += 1
        postfix = "fail_#{fail}"
      end

      postfix = "#{runs}_#{test_name}_" + postfix
      postfix = '0' + postfix if runs <= 9

      log_file = LogArtifact.new result_dir: result_dir, pass_str: pass_str, test_name: test_name

      # File.open 'w' will not create folders. Use mkdir_p before.
      test_file_path = log_file.name("#{postfix}.html")
      FileUtils.mkdir_p File.dirname(test_file_path)
      # html Ruby test log
      File.open(test_file_path, 'w') do |f|
        f.write log
      end

      # TODO: Get iOS simulator system log from appium
      # File.open(log_file.name("#{postfix}.server.log.txt"), 'w') do |f|
      #  f.write appium.tail.out.readpartial(999_999_999)
      # end

      unless sauce
        # adb logcat log
        logcat = appium.logcat ? appium.logcat.stop : nil
        logcat_file_path = log_file.name("#{postfix}.logcat.txt")
        FileUtils.mkdir_p File.dirname(logcat_file_path)
        File.open(logcat_file_path, 'w') do |f|
          f.write logcat
        end if logcat

        # appium server log
        appium_server_path = log_file.name("#{postfix}.appium.html")
        FileUtils.mkdir_p File.dirname(appium_server_path)
        File.open(appium_server_path, 'w') do |f|
          # this may return nil
          tmp_file = appium.flush_buffer

          if !tmp_file.nil? && !tmp_file.empty?
            f.write File.read tmp_file
            File.delete tmp_file
          end
        end
      end

      passed
    end

    def collect_crashes array
      Dir.glob(File.join(Dir.home, '/Library/Logs/DiagnosticReports/*.crash')) do |crash|
        array << crash
      end
      array
    end

    def execute opts={}
      run_cmd = opts[:run_cmd]
      test_name = opts[:test_name]
      appium = opts[:appium]
      sauce = opts[:sauce]

      old_crash_files = []
      # appium is nil when on sauce
      if !sauce && appium && appium.ios
        collect_crashes old_crash_files
      end

      raise 'must pass :run_cmd' unless run_cmd
      raise 'must pass :test_name' unless test_name
      # local appium is not required when running on Sauce
      raise 'must pass :appium' unless appium || sauce

      test = @tests[test_name] ||= {runs: 0, pass: 0, fail: 0}
      runs = test[:runs] += 1

      passed = _execute run_cmd, test_name, runs, appium, sauce
      unless sauce
      print cyan("\n #{test_name} ") if @last_test.nil? ||
          @last_test != test_name

      print passed ? green(' ✓') : red(' ✖')
      else
        print cyan("\n #{test_name} ")
        print passed ? green(' ✓') : red(' ✖')
        print "https://saucelabs.com/tests/#{File.read('/tmp/appium_lib_session').chomp}\n"
      end

      # appium is nil when running on Sauce
      if !sauce && appium && appium.ios
        new_crash_files = []
        collect_crashes new_crash_files

        new_crash_files = new_crash_files - old_crash_files
        if new_crash_files.length > 0
          File.open('/tmp/flaky/crashes.txt', 'a') do |f|
            f.puts '--'
            f.puts "Test: #{test_name} crashed on iOS:"
            new_crash_files.each { |crash| f.puts crash }
            f.puts '--'
          end
        end
      end

      @last_test = test_name
      passed
    end
  end # class Run
end # module Flaky