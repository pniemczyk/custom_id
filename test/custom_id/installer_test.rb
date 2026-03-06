# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

module CustomId
  class InstallerTest < Minitest::Test
    def setup
      @tmpdir = Dir.mktmpdir("custom_id_installer_test")
      @root   = Pathname.new(@tmpdir)
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    # --- install! ------------------------------------------------------------

    def test_install_creates_the_initializer_file
      Installer.install!(@root)

      assert_predicate target, :exist?, "Expected initializer to be created at #{target}"
    end

    def test_install_returns_created_on_success
      result = Installer.install!(@root)

      assert_equal :created, result
    end

    def test_install_returns_skipped_when_file_already_exists
      Installer.install!(@root)
      result = Installer.install!(@root)

      assert_equal :skipped, result
    end

    def test_install_does_not_modify_existing_file
      Installer.install!(@root)
      original_content = target.read

      Installer.install!(@root)

      assert_equal original_content, target.read
    end

    def test_install_creates_intermediate_directories
      # config/initializers/ does not exist yet
      refute_predicate (@root / "config"), :exist?
      Installer.install!(@root)

      assert_predicate (@root / "config" / "initializers"), :exist?
    end

    # --- initializer content -------------------------------------------------

    def test_initializer_contains_on_load_hook
      Installer.install!(@root)

      assert_includes target.read, "ActiveSupport.on_load(:active_record)"
    end

    def test_initializer_includes_concern
      Installer.install!(@root)

      assert_includes target.read, "include CustomId::Concern"
    end

    def test_initializer_has_frozen_string_literal_comment
      Installer.install!(@root)

      assert target.read.start_with?("# frozen_string_literal: true")
    end

    # --- uninstall! ----------------------------------------------------------

    def test_uninstall_removes_the_initializer_file
      Installer.install!(@root)
      Installer.uninstall!(@root)

      refute_predicate target, :exist?, "Expected initializer to be removed"
    end

    def test_uninstall_returns_removed_when_file_existed
      Installer.install!(@root)
      result = Installer.uninstall!(@root)

      assert_equal :removed, result
    end

    def test_uninstall_returns_skipped_when_file_does_not_exist
      result = Installer.uninstall!(@root)

      assert_equal :skipped, result
    end

    # --- INITIALIZER_PATH constant -------------------------------------------

    def test_initializer_path_constant_is_a_pathname
      assert_kind_of Pathname, Installer::INITIALIZER_PATH
    end

    def test_initializer_path_points_to_config_initializers
      assert_equal "config/initializers/custom_id.rb",
                   Installer::INITIALIZER_PATH.to_s
    end

    private

    def target
      @root.join(Installer::INITIALIZER_PATH)
    end
  end
end
