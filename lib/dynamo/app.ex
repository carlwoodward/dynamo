defmodule Dynamo.App do
  @moduledoc """
  `Dynamo.App` is a module that helps you define your
  application behavior globally.

  A `Dynamo.App` can be used on top of a `Dynamo.Router`,
  so you can route and point to other endpoints easily.

  ## Configuration

  Dynamo comes with a configuration API that allows a
  developer to customize how dynamo works and custom
  extensions.

  For example, here is a snippet that configures Dynamo
  to serve public assets from the :myapp application
  everytime we have a request at `/public`:

      config :dynamo,
        public_root:  :myapp,
        public_route: "/public"

  The available `:dynamo` configurations are:

  * `:public_route` - The route to trigger public assets serving
  * `:compile_on_demand` - Compiles modules as they are needed
  * `:reload_modules` - Reload modules after they are changed
  * `:source_paths` - The paths to search when compiling modules on demand
  * `:view_paths` - The paths to find views
  * `:root` - The application root
  * `:handler` - The handler used to serve web applications
  * `:otp_app` - The otp application associated to this app

  ## Filters

  A `Dynamo.App` also contains a set of filters that are meant
  to be used throughout your whole application. Some of these
  filters are added based on your configuration option. The
  filters included by default and when they are included are:

  * `Dynamo.Filters.Static` - when a public_route and public_root are set,
     we add this filter to serve static assets;
  * `Dynamo.Filters.Reloader` - when `:compile_on_demand` or `:reload_modules`
    configs are set to true, allowing code to be compiled and reloaded on demand;
  * `Dynamo.Filters.Head` - converts HEAD requests to GET;

  Filters can be added and removed using `filter` and `remove_filter`
  macros. You can get the list of application filters using:
  `mix dynamo.filters`.

  For more information, check `Dynamo.Router.Filters` docs.

  ## Initialization

  `Dynamo.App` allows you to register initializers which are
  invoked when the application starts. A Dynamo application
  is initialized in three steps:

  * The dynamo framework needs to be loaded via Dynamo.start
  * The application needs to be loaded via APP.start
  * A handler needs to be run to serve an application

  The step 2 can be extended via initializers. For example:

      defmodule MyApp do
        use Dynamo.App

        initializer :some_config do
          # Connect to the database
        end
      end

  By default, the application ships with 3 initializers:

  * `:start_dynamo_reloader` - starts the code reloader, usually
    used in development and test

  * `:start_dynamo_app` - starts the Dynamo application registered as `otp_app`

  * `:ensure_endpoint_is_available` - ensure the endpoint is available
    and raises a meaningful error message if not

  """

  @doc false
  defmacro __using__(_) do
    quote do
      @dynamo_app true

      @before_compile { unquote(__MODULE__), :normalize_options }
      @before_compile { unquote(__MODULE__), :load_env }
      @before_compile { unquote(__MODULE__), :apply_filters }
      @before_compile { unquote(__MODULE__), :apply_initializers }

      use Dynamo.Utils.Once

      use_once Dynamo.App.Config
      use_once Dynamo.App.Runner
      use_once Dynamo.Router.Filters

      filter Dynamo.Filters.Head

      config :dynamo, Dynamo.App.default_options(__FILE__)

      # The reloader needs to be the first initializer
      initializer :start_dynamo_reloader do
        dynamo = config[:dynamo]
        if dynamo[:compile_on_demand] do
          Dynamo.Reloader.start_link dynamo[:source_paths]
          Dynamo.Reloader.enable!
          IEx.preload.after_spawn(fn -> Dynamo.Reloader.enable! end)
        end
      end

      # Then starts up the application
      initializer :start_dynamo_app do
        if app = config[:dynamo][:otp_app] do
          :application.start(app)
        end
      end

      if @dynamo_registration != false do
        @on_load :register_dynamo_app

        defp register_dynamo_app do
          Dynamo.app(__MODULE__)
        end
      end
    end
  end

  @doc false
  def default_options(file) do
    [ public_route: "/public",
      compile_on_demand: false,
      reload_modules: false,
      source_paths: ["app/*"],
      view_paths: ["app/views"],
      root: File.expand_path("../..", file) ]
  end

  @doc false
  def config_filters(mod) do
    filters = []
    dynamo  = Module.read_attribute(mod, :config)[:dynamo]

    public_route = dynamo[:public_route]
    public_root  = case dynamo[:public_root] do
      nil   -> dynamo[:otp_app]
      other -> other
    end

    if public_root && public_route do
      filters = [Dynamo.Filters.Static.new(public_route, public_root)|filters]
    end

    if dynamo[:compile_on_demand] || dynamo[:reload_modules] do
      filters = [Dynamo.Filters.Reloader.new(dynamo[:compile_on_demand], dynamo[:reload_modules])|filters]
    end

    filters
  end

  @doc false
  defmacro normalize_options(mod) do
    dynamo = Module.read_attribute(mod, :config)[:dynamo]
    root   = dynamo[:root]

    source = dynamo[:source_paths]
    source = Enum.reduce source, [], fn(path, acc) -> expand_paths(path, root) ++ acc end

    view = dynamo[:view_paths]
    view = Enum.reduce view, [], fn(path, acc) -> expand_paths(path, root) ++ acc end

    quote do
      config :dynamo,
        view_paths: unquote(view),
        source_paths: unquote(source)
    end
  end

  defp expand_paths(path, root) do
    path /> File.expand_path(root) /> File.wildcard
  end

  @doc false
  defmacro load_env(module) do
    root = Module.read_attribute(module, :config)[:dynamo][:root]
    if root && File.dir?("#{root}/config/environments") do
      file = "#{root}/config/environments/#{Dynamo.env}.exs"
      Code.string_to_ast! File.read!(file), file: file
    end
  end

  @doc false
  defmacro apply_filters(_) do
    quote location: :keep do
      Enum.each Dynamo.App.config_filters(__MODULE__), prepend_filter(&1)
      @__reverse_filters Enum.reverse @__filters
      def filters, do: @__reverse_filters
    end
  end

  @doc false
  defmacro apply_initializers(_) do
    quote location: :keep do
      initializer :ensure_endpoint_is_available do
        if @endpoint && not Code.ensure_compiled?(@endpoint) do
          if config[:dynamo][:compile_on_demand] do
            raise "could not find endpoint #{inspect @endpoint}, please ensure it is available"
          else
            raise "could not find endpoint #{inspect @endpoint}, please ensure it was compiled"
          end
        end
      end
    end
  end
end