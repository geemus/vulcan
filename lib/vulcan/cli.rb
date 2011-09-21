require "digest/sha1"
require "net/http/post/multipart"
require "rest_client"
require "thor"
require "tmpdir"
require "uri"
require "vulcan"
require "yaml"

class Vulcan::CLI < Thor

  desc "build [COMMAND]", <<-DESC
build a piece of software for the heroku cloud using COMMANd as a build command
if no COMMAND is specified, a sensible default will be chosen for you

  DESC

  method_option :command, :aliases => "-c", :desc => "the command to run for compilation"
  method_option :name,    :aliases => "-n", :desc => "the name of the library (defaults ot the directory name)"
  method_option :output,  :aliases => "-o", :desc => "output build artifacts to this file"
  method_option :prefix,  :aliases => "-p", :desc => "the build/install --prefix of the software"
  method_option :source,  :aliases => "-s", :desc => "the source directory to build from"
  method_option :verbose, :aliases => "-v", :desc => "show the full build output", :type => :boolean

  def build
    app = read_config[:app] || "need a server first, use vulcan create"

    command = options[:command] || "./configure --prefix #{prefix} && make install"
    name    = options[:name]    || File.basename(Dir.pwd)
    output  = options[:output]  || "/tmp/#{name}.tgz"
    prefix  = options[:prefix]  || "/app/vendor/#{name}"
    source  = options[:source]  || Dir.pwd
    server  = URI.parse(ENV["MAKE_SERVER"] || "http://#{app}.herokuapp.com")

    Dir.mktmpdir do |dir|
      puts ">> Packaging local directory"
      %x{ cd #{source} && tar czvf #{dir}/input.tgz . 2>&1 }

      puts ">> Uploading code for build"
      File.open("#{dir}/input.tgz", "r") do |input|
        request = Net::HTTP::Post::Multipart.new "/make",
          "code" => UploadIO.new(input, "application/octet-stream", "input.tgz"),
          "command" => command,
          "prefix" => prefix

        puts ">> Building with: #{command}"
        response = Net::HTTP.start(server.host, server.port) do |http|
          http.request(request) do |response|
            response.read_body do |chunk|
              print chunk if options[:verbose]
            end
          end
        end

        error "Unknown error, no build output given" unless response["X-Make-Id"]

        puts ">> Downloading build artifacts to: #{output}"

        File.open(output, "w") do |output|
          begin
            output.print RestClient.get("#{server}/output/#{response["X-Make-Id"]}")
          rescue Exception => ex
            puts ex.inspect
          end
        end
      end
    end
  rescue Errno::EPIPE
    error "Could not connect to build server: #{server}"
  end

  desc "create APP_NAME", <<-DESC
create a build server on Heroku

  DESC

  def create(name)
    secret = Digest::SHA1.hexdigest("--#{rand(10000)}--#{Time.now}--")

    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        system "env BUNDLE_GEMFILE= heroku create #{name} -s cedar"
      end
    end
    write_config :ap=> name, :host => "#{name}.herokuapp.com", :secret => secret
    update
  end


  desc "update", <<-DESC
update the build server

  DESC

  def update
    error "no apyet, create first" unless config[:app]

    FileUtils.mkdir_p File.expand_path("~/.heroku/plugins/heroku-credentials")

    File.open(File.expand_path("~/.heroku/plugins/heroku-credentials/init.rb"), "w") do |file|
      file.puts <<-CONTENTS
        class Heroku::Command::Credentials < Heroku::Command::Base
          def index
            puts Heroku::Auth.password
          end
        end
      CONTENTS
    end

    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        api_key = %x{ env BUNDLE_GEMFILE= heroku credentials }

        system "git init"
        system "git remote add heroku git@heroku.com:#{config[:app]}.git"
        FileUtils.cp_r "#{server_path}/.", "."
        File.open(".gitignore", "w") do |file|
          file.puts ".env"
          file.puts "node_modules"
        end
        system "ls -la"
        system "git add ."
        system "git commit -m commit"
        system "git push heroku -f master"

        %x{ env BUNDLE_GEMFILE= heroku config:add SECRET=#{config[:secret]} SPAWN_ENV=heroku HEROKU_APP=#{config[:app]} HEROKU_API_KEY=#{api_key} 2>&1 }
        %x{ env BUNDLE_GEMFILE= heroku addons:add cloudant:oxygen }
      end
    end
  end

private

  def config_file
    File.expand_path("~/.vulcan")
  end

  def config
    read_config
  end

  def read_config
    return {} unless File.exists?(config_file)
    config = YAML.load_file(config_file)
    config.is_a?(Hash) ? config : {}
  end

  def write_config(config)
    full_config = read_config.merge(config)
    File.open(config_file, "w") do |file|
      file.puts YAML.dump(full_config)
    end
  end

  def error(message)
    puts "!! #{message}"
    exit 1
  end

  def server_path
    File.expand_path("../../../server", __FILE__)
  end

end
