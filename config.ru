require 'fileutils'

FileUtils.mkdir_p('log')
log = File.new("log/sinatra.log", "a+")
log.sync = true

require File.expand_path('app', __dir__)

use Rack::CommonLogger, log

run Server
