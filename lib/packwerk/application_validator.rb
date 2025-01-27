# typed: strict
# frozen_string_literal: true

require "constant_resolver"
require "pathname"
require "yaml"

module Packwerk
  # Checks the structure of the application and its packwerk configuration to make sure we can run a check and deliver
  # correct results.
  class ApplicationValidator
    extend T::Sig

    sig do
      params(
        config_file_path: String,
        configuration: Configuration,
        environment: String
      ).void
    end
    def initialize(config_file_path:, configuration:, environment:)
      @config_file_path = config_file_path
      @configuration = configuration
      @environment = environment
      @package_set = T.let(PackageSet.load_all_from(@configuration.root_path, package_pathspec: package_glob),
        PackageSet)
    end

    class Result < T::Struct
      extend T::Sig

      const :ok, T::Boolean
      const :error_value, T.nilable(String)

      sig { returns(T::Boolean) }
      def ok?
        ok
      end
    end

    sig { returns(Result) }
    def check_all
      results = [
        check_package_manifests_for_privacy,
        check_package_manifest_syntax,
        check_application_structure,
        check_acyclic_graph,
        check_package_manifest_paths,
        check_valid_package_dependencies,
        check_root_package_exists,
      ]

      merge_results(results)
    end

    sig { returns(Result) }
    def check_package_manifests_for_privacy
      privacy_settings = package_manifests_settings_for("enforce_privacy")

      resolver = ConstantResolver.new(
        root_path: @configuration.root_path,
        load_paths: @configuration.load_paths
      )

      results = T.let([], T::Array[Result])

      privacy_settings.each do |config_file_path, setting|
        next unless setting.is_a?(Array)
        constants = setting

        results += assert_constants_can_be_loaded(constants, config_file_path)

        constant_locations = constants.map { |c| [c, resolver.resolve(c)&.location] }

        constant_locations.each do |name, location|
          results << if location
            check_private_constant_location(name, location, config_file_path)
          else
            private_constant_unresolvable(name, config_file_path)
          end
        end
      end

      merge_results(results, separator: "\n---\n")
    end

    sig { returns(Result) }
    def check_package_manifest_syntax
      errors = []

      package_manifests.each do |f|
        hash = YAML.load_file(f)
        next unless hash

        known_keys = %w(enforce_privacy enforce_dependencies public_path dependencies metadata)
        unknown_keys = hash.keys - known_keys

        unless unknown_keys.empty?
          errors << "Unknown keys in #{f}: #{unknown_keys.inspect}\n"\
            "If you think a key should be included in your package.yml, please "\
            "open an issue in https://github.com/Shopify/packwerk"
        end

        if hash.key?("enforce_privacy")
          unless [TrueClass, FalseClass, Array].include?(hash["enforce_privacy"].class)
            errors << "Invalid 'enforce_privacy' option in #{f.inspect}: #{hash["enforce_privacy"].inspect}"
          end
        end

        if hash.key?("enforce_dependencies")
          unless [TrueClass, FalseClass].include?(hash["enforce_dependencies"].class)
            errors << "Invalid 'enforce_dependencies' option in #{f.inspect}: #{hash["enforce_dependencies"].inspect}"
          end
        end

        if hash.key?("public_path")
          unless hash["public_path"].is_a?(String)
            errors << "'public_path' option must be a string in #{f.inspect}: #{hash["public_path"].inspect}"
          end
        end

        next unless hash.key?("dependencies")
        next if hash["dependencies"].is_a?(Array)

        errors << "Invalid 'dependencies' option in #{f.inspect}: #{hash["dependencies"].inspect}"
      end

      if errors.empty?
        Result.new(ok: true)
      else
        Result.new(ok: false, error_value: errors.join("\n---\n"))
      end
    end

    sig { returns(Result) }
    def check_application_structure
      resolver = ConstantResolver.new(
        root_path: @configuration.root_path.to_s,
        load_paths: @configuration.load_paths
      )

      begin
        resolver.file_map
        Result.new(ok: true)
      rescue => e
        Result.new(ok: false, error_value: e.message)
      end
    end

    sig { returns(Result) }
    def check_acyclic_graph
      edges = @package_set.flat_map do |package|
        package.dependencies.map { |dependency| [package, @package_set.fetch(dependency)] }
      end
      dependency_graph = Graph.new(*T.unsafe(edges))

      cycle_strings = build_cycle_strings(dependency_graph.cycles)

      if dependency_graph.acyclic?
        Result.new(ok: true)
      else
        Result.new(
          ok: false,
          error_value: <<~EOS
            Expected the package dependency graph to be acyclic, but it contains the following cycles:

            #{cycle_strings.join("\n")}
          EOS
        )
      end
    end

    sig { returns(Result) }
    def check_package_manifest_paths
      all_package_manifests = package_manifests("**/")
      package_paths_package_manifests = package_manifests(package_glob)

      difference = all_package_manifests - package_paths_package_manifests

      if difference.empty?
        Result.new(ok: true)
      else
        Result.new(
          ok: false,
          error_value: <<~EOS
            Expected package paths for all package.ymls to be specified, but paths were missing for the following manifests:

            #{relative_paths(difference).join("\n")}
          EOS
        )
      end
    end

    sig { returns(Result) }
    def check_valid_package_dependencies
      packages_dependencies = package_manifests_settings_for("dependencies")
        .delete_if { |_, deps| deps.nil? }

      packages_with_invalid_dependencies =
        packages_dependencies.each_with_object([]) do |(package, dependencies), invalid_packages|
          invalid_dependencies = dependencies.filter { |path| invalid_package_path?(path) }
          invalid_packages << [package, invalid_dependencies] if invalid_dependencies.any?
        end

      if packages_with_invalid_dependencies.empty?
        Result.new(ok: true)
      else
        error_locations = packages_with_invalid_dependencies.map do |package, invalid_dependencies|
          package ||= @configuration.root_path
          package_path = Pathname.new(package).relative_path_from(@configuration.root_path)
          all_invalid_dependencies = invalid_dependencies.map { |d| "  - #{d}" }

          <<~EOS
            #{package_path}:
            #{all_invalid_dependencies.join("\n")}
          EOS
        end

        Result.new(
          ok: false,
          error_value: <<~EOS
            These dependencies do not point to valid packages:

            #{error_locations.join("\n")}
          EOS
        )
      end
    end

    sig { returns(Result) }
    def check_root_package_exists
      root_package_path = File.join(@configuration.root_path, "package.yml")
      all_packages_manifests = package_manifests(package_glob)

      if all_packages_manifests.include?(root_package_path)
        Result.new(ok: true)
      else
        Result.new(
          ok: false,
          error_value: <<~EOS
            A root package does not exist. Create an empty `package.yml` at the root directory.
          EOS
        )
      end
    end

    private

    # Convert the cycles:
    #
    #   [[a, b, c], [b, c]]
    #
    # to the string:
    #
    #   ["a -> b -> c -> a", "b -> c -> b"]
    sig { params(cycles: T.untyped).returns(T::Array[String]) }
    def build_cycle_strings(cycles)
      cycles.map do |cycle|
        cycle_strings = cycle.map(&:to_s)
        cycle_strings << cycle.first.to_s
        "\t- #{cycle_strings.join(" → ")}"
      end
    end

    sig { params(setting: T.untyped).returns(T.untyped) }
    def package_manifests_settings_for(setting)
      package_manifests.map { |f| [f, (YAML.load_file(File.join(f)) || {})[setting]] }
    end

    sig { params(list: T.untyped).returns(T.untyped) }
    def format_yaml_strings(list)
      list.sort.map { |p| "- \"#{p}\"" }.join("\n")
    end

    sig { returns(T.any(T::Array[String], String)) }
    def package_glob
      @configuration.package_paths || "**"
    end

    sig { params(glob_pattern: T.any(T::Array[String], String)).returns(T::Array[String]) }
    def package_manifests(glob_pattern = package_glob)
      PackageSet.package_paths(@configuration.root_path, glob_pattern, @configuration.exclude)
        .map { |f| File.realpath(f) }
    end

    sig { params(paths: T::Array[String]).returns(T::Array[Pathname]) }
    def relative_paths(paths)
      paths.map { |path| relative_path(path) }
    end

    sig { params(path: String).returns(Pathname) }
    def relative_path(path)
      Pathname.new(path).relative_path_from(@configuration.root_path)
    end

    sig { params(path: T.untyped).returns(T::Boolean) }
    def invalid_package_path?(path)
      # Packages at the root can be implicitly specified as "."
      return false if path == "."

      package_path = File.join(@configuration.root_path, path, PackageSet::PACKAGE_CONFIG_FILENAME)
      !File.file?(package_path)
    end

    sig { params(constants: T.untyped, config_file_path: String).returns(T::Array[Result]) }
    def assert_constants_can_be_loaded(constants, config_file_path)
      constants.map do |constant|
        if !constant.start_with?("::")
          Result.new(
            ok: false,
            error_value: "'#{constant}', listed in the 'enforce_privacy' option in #{config_file_path}, is invalid.\n"\
            "Private constants need to be prefixed with the top-level namespace operator `::`."
          )
        else
          constant.try(&:constantize) && Result.new(ok: true)
        end
      end
    end

    sig { params(name: T.untyped, config_file_path: T.untyped).returns(Result) }
    def private_constant_unresolvable(name, config_file_path)
      explicit_filepath = (name.start_with?("::") ? name[2..-1] : name).underscore + ".rb"

      Result.new(
        ok: false,
        error_value: "'#{name}', listed in #{config_file_path}, could not be resolved.\n"\
        "This is probably because it is an autovivified namespace - a namespace module that doesn't have a\n"\
        "file explicitly defining it. Packwerk currently doesn't support declaring autovivified namespaces as\n"\
        "private. Add a #{explicit_filepath} file to explicitly define the constant."
      )
    end

    sig { params(name: T.untyped, location: T.untyped, config_file_path: T.untyped).returns(Result) }
    def check_private_constant_location(name, location, config_file_path)
      declared_package = @package_set.package_from_path(relative_path(config_file_path))
      constant_package = @package_set.package_from_path(location)

      if constant_package == declared_package
        Result.new(ok: true)
      else
        Result.new(
          ok: false,
          error_value: "'#{name}' is declared as private in the '#{declared_package}' package but appears to be "\
          "defined\nin the '#{constant_package}' package. Packwerk resolved it to #{location}."
        )
      end
    end

    sig do
      params(results: T::Array[Result], separator: String, errors_headline: String).returns(Result)
    end
    def merge_results(results, separator: "\n===\n", errors_headline: "")
      results.reject!(&:ok?)

      if results.empty?
        Result.new(ok: true)
      else
        Result.new(
          ok: false,
          error_value: errors_headline + results.map(&:error_value).join(separator)
        )
      end
    end
  end
end
