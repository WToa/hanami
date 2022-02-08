# frozen_string_literal: true

require "dry/system/container"
require "dry/system/loader/autoloading"
require "hanami/configuration"
require "pathname"
require "rack"
require "zeitwerk"
require_relative "slice"

module Hanami
  # Hanami application class
  #
  # @since 2.0.0
  class Application
    @_mutex = Mutex.new

    class << self
      def inherited(klass)
        @_mutex.synchronize do
          klass.class_eval do
            @_mutex         = Mutex.new
            @_configuration = Hanami::Configuration.new(application_name: name, env: Hanami.env)

            extend ClassMethods
          end

          klass.send :prepare_base_load_path

          Hanami.application = klass
        end
      end
    end

    # Application class interface
    #
    # rubocop:disable Metrics/ModuleLength
    module ClassMethods
      def self.extended(klass)
        klass.class_eval do
          @prepared = @booted = false
        end
      end

      def configuration
        @_configuration
      end

      alias config configuration

      def prepare(provider_name = nil) # rubocop:disable Metrics/MethodLength
        if provider_name
          container.prepare(provider_name)
          return self
        end

        return self if prepared?

        configuration.finalize!

        load_settings

        @autoloader = Zeitwerk::Loader.new
        @container = prepare_container
        @deps_module = prepare_deps_module

        load_slices
        slices.each_value(&:prepare)
        slices.freeze

        @autoloader.setup

        @prepared = true
        self
      end

      def boot(&block)
        return self if booted?

        prepare

        container.finalize!(&block)

        slices.values.each(&:boot)

        @booted = true
        self
      end

      def shutdown
        container.shutdown!
      end

      def prepared?
        @prepared
      end

      def booted?
        @booted
      end

      def autoloader
        raise "Application not yet prepared" unless defined?(@autoloader)

        @autoloader
      end

      def container
        raise "Application not yet prepared" unless defined?(@container)

        @container
      end

      def deps
        raise "Application not yet prepared" unless defined?(@deps_module)

        @deps_module
      end

      def router
        raise "Application not yet prepared" unless prepared?

        @_mutex.synchronize do
          @_router ||= load_router
        end
      end

      def rack_app
        @rack_app ||= router.to_rack_app
      end

      def slices
        @slices ||= {}
      end

      def register_slice(name, **slice_args)
        raise "Slice +#{name}+ already registered" if slices.key?(name.to_sym)

        slice = Slice.new(self, name: name, **slice_args)
        slice.namespace.const_set :Slice, slice if slice.namespace # rubocop:disable Style/SafeNavigation
        slices[name.to_sym] = slice
      end

      def register(...)
        container.register(...)
      end

      def register_provider(...)
        container.register_provider(...)
      end

      def start(...)
        container.start(...)
      end

      def key?(...)
        container.key?(...)
      end

      def keys
        container.keys
      end

      def [](...)
        container.[](...)
      end

      def resolve(...)
        container.resolve(...)
      end

      def settings
        @_settings ||= load_settings
      end

      def namespace
        configuration.namespace
      end

      def namespace_name
        namespace.name
      end

      def namespace_path
        inflector.underscore(namespace)
      end

      def application_name
        configuration.application_name
      end

      def root
        configuration.root
      end

      def inflector
        configuration.inflector
      end

      # @api private
      def component_provider(component)
        raise "Hanami.application must be prepared before detecting providers" unless prepared?

        # [Admin, Main, MyApp] or [MyApp::Admin, MyApp::Main, MyApp]
        providers = slices.values + [self]

        component_class = component.is_a?(Class) ? component : component.class
        component_name = component_class.name

        return unless component_name

        providers.detect { |provider| component_name.include?(provider.namespace.to_s) }
      end

      private

      def prepare_base_load_path
        base_path = File.join(root, "lib")
        $LOAD_PATH.unshift base_path unless $LOAD_PATH.include?(base_path)
      end

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
      def prepare_container
        container =
          begin
            require "#{application_name}/container"
            namespace.const_get :Container
          rescue LoadError, NameError
            namespace.const_set :Container, Class.new(Dry::System::Container)
          end

        container.use :env, inferrer: -> { Hanami.env }
        container.use :zeitwerk, loader: autoloader, run_setup: false, eager_load: false
        container.use :notifications

        container.config.root = configuration.root
        container.config.inflector = configuration.inflector

        container.config.provider_dirs = [
          "config/providers",
          Pathname(__dir__).join("application/container/providers").realpath,
        ]

        # Autoload classes defined in lib/[app_namespace]/
        if root.join("lib", namespace_path).directory?
          container.autoloader.push_dir(root.join("lib", namespace_path), namespace: namespace)
        end

        # Add lib/ to to the $LOAD_PATH so any files there (outside the app namespace) can
        # be required
        container.add_to_load_path!("lib") if root.join("lib").directory?

        container.configured!

        container
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

      def prepare_deps_module
        define_deps_module
      end

      def define_deps_module
        require "#{application_name}/deps"
        namespace.const_get :Deps
      rescue LoadError, NameError
        namespace.const_set :Deps, container.injector
      end

      def load_slices
        Dir[File.join(slices_path, "*")]
          .select(&File.method(:directory?))
          .each(&method(:load_slice))
      end

      def slices_path
        File.join(root, config.slices_dir)
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def load_slice(slice_path)
        slice_path = Pathname(slice_path)

        slice_name = slice_path.relative_path_from(Pathname(slices_path)).to_s
        slice_const_name = inflector.camelize(slice_name)

        if config.slices_namespace.const_defined?(slice_const_name)
          slice_module = config.slices_namespace.const_get(slice_const_name)

          raise "Cannot use slice +#{slice_const_name}+ since it is not a module" unless slice_module.is_a?(Module)
        else
          slice_module = Module.new
          config.slices_namespace.const_set inflector.camelize(slice_name), slice_module
        end

        register_slice(
          slice_name,
          namespace: slice_module,
          root: slice_path.realpath
        )
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def load_settings
        require_relative "application/settings"

        prepare_base_load_path
        require File.join(configuration.root, configuration.settings_path)
        settings_class = autodiscover_application_constant(configuration.settings_class_name)
        settings_class.new(configuration.settings_store)
      rescue LoadError
        Settings.new
      end

      MODULE_DELIMITER = "::"
      private_constant :MODULE_DELIMITER

      def autodiscover_application_constant(constants)
        inflector.constantize([namespace_name, *constants].join(MODULE_DELIMITER))
      end

      def load_router
        require_relative "application/router"

        Router.new(
          routes: load_routes,
          resolver: router_resolver,
          **configuration.router.options,
        ) do
          use Hanami.application[:rack_monitor]

          Hanami.application.config.for_each_middleware do |m, *args, &block|
            use(m, *args, &block)
          end
        end
      end

      def load_routes
        require_relative "application/routes"

        require File.join(configuration.root, configuration.router.routes_path)
        routes_class = autodiscover_application_constant(configuration.router.routes_class_name)
        routes_class.routes
      rescue LoadError
        proc {}
      end

      def router_resolver
        config.router.resolver.new(
          slices: slices,
          inflector: inflector
        )
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
