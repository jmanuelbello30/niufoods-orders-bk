require "test_helper"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

class DotenvConfigurationTest < Minitest::Test
  def test_parent_uses_only_the_empty_fixture
    assert Rails.env.test?
    assert_equal [ Rails.root.join("test/fixtures/files/empty.env").to_s ], Dotenv::Rails.files
    assert_equal false, Dotenv::Rails.overwrite
    assert_match(/\Aniufoods_orders_test(?:_\d+)?\z/,
      ActiveRecord::Base.connection_db_config.database.to_s)
  end

  def test_development_and_test_load_credentials_through_the_railtie_hook
    %w[development test].each do |environment|
      Dir.mktmpdir("dotenv-configuration-") do |directory|
        File.write(File.join(directory, ".env"), <<~ENV_FILE)
          DEMO_USER_EMAIL=fixture@example.test
          DEMO_USER_PASSWORD=fixture-password-123
        ENV_FILE

        assert_fixture_environment(directory, environment,
          expected: [ "fixture@example.test", "fixture-password-123" ])
      end
    end
  end

  def test_terminal_credentials_including_empty_values_take_priority
    %w[development test].each do |environment|
      Dir.mktmpdir("dotenv-configuration-") do |directory|
        File.write(File.join(directory, ".env"), <<~ENV_FILE)
          DEMO_USER_EMAIL=fixture@example.test
          DEMO_USER_PASSWORD=fixture-password-123
        ENV_FILE

        [ [ "terminal@example.test", "terminal-password-123" ], [ "", "" ] ].each do |values|
          assert_fixture_environment(directory, environment, expected: values,
            variables: { "DEMO_USER_EMAIL" => values.first, "DEMO_USER_PASSWORD" => values.last })
        end
      end
    end
  end

  def test_unedited_example_leaves_credentials_absent_without_inheriting_parent_values
    Dotenv.modify("DEMO_USER_EMAIL" => "parent@example.test", "DEMO_USER_PASSWORD" => "parent-password-123") do
      %w[development test].each do |environment|
        Dir.mktmpdir("dotenv-configuration-") do |directory|
          FileUtils.cp(Rails.root.join(".env.example"), File.join(directory, ".env"))

          assert_fixture_environment(directory, environment, expected: [ nil, nil ])
        end
      end
    end
  end

  def test_production_does_not_load_dotenv_or_temporary_credentials
    Dir.mktmpdir("dotenv-configuration-") do |directory|
      File.write(File.join(directory, ".env"), <<~ENV_FILE)
        DEMO_USER_EMAIL=fixture@example.test
        DEMO_USER_PASSWORD=fixture-password-123
      ENV_FILE

      assert_fixture_environment(directory, "production", expected: [ nil, nil ])
    end
  end

  def test_rake_test_selects_the_empty_fixture_before_rails_changes_environment
    Dir.mktmpdir("dotenv-rake-") do |directory|
      File.write(File.join(directory, ".env"), <<~ENV_FILE)
        DEMO_USER_EMAIL=fixture@example.test
        DEMO_USER_PASSWORD=fixture-password-123
      ENV_FILE
      script = <<~RUBY
        require "bundler/setup"
        require "rails/all"
        require "rake"
        Rake.application.top_level_tasks << "test"
        Bundler.require(*Rails.groups)

        fixture_root = Pathname.new(ARGV.fetch(0))
        application_root = Pathname.new(ARGV.fetch(1))
        # Even a regression must only open temporary dotenv files, never developer files.
        Dotenv::Rails.instance.define_singleton_method(:root) { fixture_root }
        require application_root.join("config/application").to_s

        abort "Expected the early development environment" unless Rails.env.development?
        abort "Rake test environment not detected" unless Dotenv::Rails.env.test?
        expected_file = application_root.join("test/fixtures/files/empty.env").to_s
        abort "Unsafe Rake dotenv file selection" unless Dotenv::Rails.files == [expected_file]
        abort "Unexpected demo credentials" if ENV.key?("DEMO_USER_EMAIL") || ENV.key?("DEMO_USER_PASSWORD")
        abort "Unexpected application initialization" if Rails.application.initialized?
        puts "DOTENV_RAKE_ISOLATION_OK"
      RUBY
      output, _errors, status = Open3.capture3(
        { "BUNDLE_GEMFILE" => Rails.root.join("Gemfile").to_s,
          "PATH" => File.dirname(RbConfig.ruby) + File::PATH_SEPARATOR + "/usr/bin:/bin",
          "HOME" => directory, "RAILS_ENV" => nil, "DEMO_USER_EMAIL" => nil, "DEMO_USER_PASSWORD" => nil },
        RbConfig.ruby, "-e", script, directory, Rails.root.to_s,
        chdir: directory, unsetenv_others: true
      )
      assert status.success?, "Isolated Rake test dotenv check failed"
      assert_equal "DOTENV_RAKE_ISOLATION_OK\n", output
    end
  end

  private
    def assert_fixture_environment(directory, environment, expected:, variables: {})
      script = <<~RUBY
        require "bundler/setup"
        require "rails/all"
        Bundler.require(*Rails.groups)

        if Rails.env.production?
          abort "Unexpected dotenv dependency" if defined?(Dotenv)
        else
          abort "Missing dotenv integration" unless defined?(Dotenv::Rails)
          abort "Unexpected overwrite configuration" unless Dotenv::Rails.overwrite == false
        end

        Dotenv::Rails.files = ARGV if defined?(Dotenv::Rails)

        class FixtureApplication < Rails::Application
        end

        abort "Unexpected application initialization" if FixtureApplication.initialized?
        unless ENV.values_at("DEMO_USER_EMAIL", "DEMO_USER_PASSWORD") == #{expected.inspect}
          abort "Unexpected demo environment configuration"
        end
        puts "DOTENV_CONFIGURATION_OK"
      RUBY
      environment_variables = {
        "BUNDLE_GEMFILE" => Rails.root.join("Gemfile").to_s,
        "PATH" => File.dirname(RbConfig.ruby) + File::PATH_SEPARATOR + "/usr/bin:/bin",
        "HOME" => directory,
        "RAILS_ENV" => environment,
        "DEMO_USER_EMAIL" => nil,
        "DEMO_USER_PASSWORD" => nil
      }.merge(variables)

      output, _errors, status = Open3.capture3(environment_variables,
        RbConfig.ruby, "-e", script, File.join(directory, ".env"),
        chdir: directory, unsetenv_others: true)

      assert status.success?, "Isolated Rails dotenv check failed for #{environment}"
      assert_equal "DOTENV_CONFIGURATION_OK\n", output, "Unexpected subprocess output"
    end
end
