# Built on Rack
require 'rack'
require 'rack/file'
require 'rack/lint'
require 'rack/head'

require 'middleman-core/util'
require 'middleman-core/template_renderer'

module Middleman
  module CoreExtensions

    # Base helper to manipulate asset paths
    module Request

      # Extension registered
      class << self
        # @private
        def included(app)
          # CSSPIE HTC File
          ::Rack::Mime::MIME_TYPES['.htc'] = 'text/x-component'

          # Let's serve all HTML as UTF-8
          ::Rack::Mime::MIME_TYPES['.html'] = 'text/html; charset=utf-8'
          ::Rack::Mime::MIME_TYPES['.htm'] = 'text/html; charset=utf-8'

          app.extend ClassMethods
          app.extend ServerMethods

          Middleman.extend CompatibleClassMethods

          # Include instance methods
          app.send :include, InstanceMethods
        end
      end

      module ClassMethods
        # Reset Rack setup
        #
        # @private
        def reset!
          @rack_app = nil
        end

        # Get the static instance
        #
        # @private
        # @return [Middleman::Application]
        def inst(&block)
          @inst ||= begin
            mm = new(&block)
            mm.run_hook :ready
            mm.config_context.execute_ready_callbacks
            mm
          end
        end

        # Set the shared instance
        #
        # @private
        # @param [Middleman::Application] inst
        # @return [void]
        def inst=(inst)
          @inst = inst
        end

        # Return built Rack app
        #
        # @private
        # @return [Rack::Builder]
        def to_rack_app(&block)
          @rack_app ||= begin
            app = ::Rack::Builder.new
            app.use Rack::Lint
            app.use Rack::Head

            Array(@middleware).each do |klass, options, block|
              app.use(klass, *options, &block)
            end

            inner_app = inst(&block)
            app.map('/') { run inner_app }

            Array(@mappings).each do |path, block|
              app.map(path, &block)
            end

            app
          end
        end

        # Prototype app. Used in config.ru
        #
        # @private
        # @return [Rack::Builder]
        def prototype
          reset!
          to_rack_app
        end

        # Call prototype, use in config.ru
        #
        # @private
        def call(env)
          prototype.call(env)
        end

        # Use Rack middleware
        #
        # @param [Class] middleware Middleware module
        # @return [void]
        def use(middleware, *args, &block)
          @middleware ||= []
          @middleware << [middleware, args, block]
        end

        # Add Rack App mapped to specific path
        #
        # @param [String] map Path to map
        # @return [void]
        def map(map, &block)
          @mappings ||= []
          @mappings << [map, block]
        end
      end

      module ServerMethods
        # Create a new Class which is based on Middleman::Application
        # Used to create a safe sandbox into which extensions and
        # configuration can be included later without impacting
        # other classes and instances.
        #
        # @return [Class]
        def server(&block)
          @@servercounter ||= 0
          @@servercounter += 1
          const_set("MiddlemanApplication#{@@servercounter}", Class.new(Middleman::Application, &block))
        end
      end

      module CompatibleClassMethods
        # Create a new Class which is based on Middleman::Application
        # Used to create a safe sandbox into which extensions and
        # configuration can be included later without impacting
        # other classes and instances.
        #
        # @return [Class]
        def server(&block)
          ::Middleman::Application.server(&block)
        end
      end

      # Methods to be mixed-in to Middleman::Application
      module InstanceMethods

        delegate :use, :to => :"self.class"
        delegate :map, :to => :"self.class"

        def call(env)
          dup.call!(env)
        end

        # Rack Interface
        #
        # @param env Rack environment
        def call!(env)
          # Store environment, request and response for later
          req = ::Rack::Request.new(env)
          res = ::Rack::Response.new

          logger.debug "== Request: #{env["PATH_INFO"]}"

          # Catch :halt exceptions and use that response if given
          catch(:halt) do
            process_request(env, req, res)

            res.status = 404

            res.finish
          end
        end

        # Halt the current request and return a response
        #
        # @param [String] response Response value
        def halt(response)
          throw :halt, response
        end

        # Core response method. We process the request, check with
        # the sitemap, and return the correct file, response or status
        # message.
        #
        # @param env
        # @param [Rack::Request] req
        # @param [Rack::Response] res
        def process_request(env, req, res)
          start_time = Time.now

          request_path = URI.decode(env['PATH_INFO'].dup)
          if request_path.respond_to? :force_encoding
            request_path.force_encoding('UTF-8')
          end
          request_path = ::Middleman::Util.full_path(request_path, self)

          # Run before callbacks
          run_hook :before

          # Get the resource object for this path
          resource = sitemap.find_resource_by_destination_path(request_path.gsub(' ', '%20'))

          # Return 404 if not in sitemap
          return not_found(res, request_path) unless resource && !resource.ignored?

          # If this path is a binary file, send it immediately
          return send_file(resource, env) if resource.binary?

          res['Content-Type'] = resource.content_type || 'text/plain'

          begin
            # Write out the contents of the page
            res.write resource.render

            # Valid content is a 200 status
            res.status = 200
          rescue Middleman::TemplateRenderer::TemplateNotFound => e
            res.write "Error: #{e.message}"
            res.status = 500
          end

          # End the request
          logger.debug "== Finishing Request: #{resource.destination_path} (#{(Time.now - start_time).round(2)}s)"
          halt res.finish
        end

        # Add a new mime-type for a specific extension
        #
        # @param [Symbol] type File extension
        # @param [String] value Mime type
        # @return [void]
        def mime_type(type, value)
          type = ".#{type}" unless type.to_s[0] == ?.
          ::Rack::Mime::MIME_TYPES[type] = value
        end

        # Halt request and return 404
        def not_found(res, path)
          res.status = 404
          res.write "<html><body><h1>File Not Found</h1><p>#{path}</p></body>"
          res.finish
        end

        # Immediately send static file
        def send_file(resource, env)
          file      = ::Rack::File.new nil
          file.path = resource.source_file
          response = file.serving(env)
          status = response[0]
          response[1]['Content-Encoding'] = 'gzip' if %w(.svgz .gz).include?(resource.ext)
          # Do not set Content-Type if status is 1xx, 204, 205 or 304, otherwise
          # Rack will throw an error (500)
          if !(100..199).include?(status) && ![204, 205, 304].include?(status)
            response[1]['Content-Type'] = resource.content_type || 'application/octet-stream'
          end
          halt response
        end
      end
    end
  end
end
