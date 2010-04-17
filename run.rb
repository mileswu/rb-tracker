require 'rubygems'
require 'ebb'
require 'rack'
require 'rack/showexceptions'
require 'rack/request'
require 'rack/response'
require 'rack/reloader'
require 'tracker'

app = Rack::Builder.new do
#	use Rack::ShowExceptions
#	use Rack::Reloader, 0
#	use Rack::Lint
	run Tracker.new
end

Ebb.start_server(app, :Port=>3000)
#Rack::Handler::Thin.run(app, :Port=>3000)

