require 'bencode'
require 'ipaddr'
require 'json'
require 'mysql'
require 'memcached'
require 'config'

class String
	def to_hex
		return self.unpack("H*")
	end
end

module TrackerHelper
end

class Tracker
	include TrackerHelper

	def initialize
		@db = Mysql.real_connect('localhost', MYSQL_USER, MYSQL_PASS, MYSQL_DB)
		@db.reconnect = true
		@@cache = Memcached.new("localhost:11211")



		@users = {}
		@torrents = {}
		read_users
		read_torrents
	end
	
	def call(env)
		req = Rack::Request.new(env)
		path = req.path
		if(path[-9..-1] == '/announce') # format is /<passkey>/announce
			return announce(req)
		elsif(path == '/debug')
			u = @users.inspect.scan(%r{.{1,80}}).join("\n")
			t = @torrents.inspect.scan(%r{.{1,80}}).join("\n")
			return [200, {'Content-Type' => 'text/plain'}, "#{u}\n-------\n#{t}"]
		else
			return [200, {'Content-Type' => 'text/plain'}, "WTF are you trying to do"]
		end
	end

	private

	def read_users
		t = Time.now.to_f
		results = @db.query("SELECT ID, Enabled, torrent_pass FROM users_main")

		passkeys = []
		results.each_hash do |i|
			if i["Enabled"] == '1'
				p = i["torrent_pass"]
				passkeys << p
				if(@users[p].nil?)
					@users[p] = { :id => i["ID"] }
				end
			end
		end
		@users.delete_if { |k, h| !passkeys.include?(k) }
		puts "Fetching users took #{Time.now.to_f - t} seconds. #{@users.length} active users"
	end
	
	def read_torrents
		t = Time.now.to_f
		results = @db.query("SELECT ID, info_hash FROM torrents")

		puts "Fetching torrents took #{Time.now.to_f - t} seconds. #{@torrents.length} active torrents"
		infohashes = []
		results.each_hash do |i|
			ih = i["info_hash"]
			infohashes << ih
			if(@torrents[ih].nil?)
				@torrents[ih] = { :peers => [], :id => i["ID"] }
			end
		end
		@torrents.delete_if { |k, h| !infohashes.include?(k) }
		puts "Fetching torrents took #{Time.now.to_f - t} seconds. #{@torrents.length} active torrents"
	end

	def announce(req)
		resp = Rack::Response.new("", 200, {'Content-Type' => 'text/plain'})
		
		passkey = req.path[1..-10]
		if passkey == ''
			resp.write({'failure reason' => 'This is private. You need a passkey'}.bencode)
			return resp.finish
		elsif (user = @users[passkey]).nil?
			resp.write({'failure reason' => 'Your passkey is invalid'}.bencode)
			return resp.finish
		end

		get_vars = req.GET()
		# GET requests of interest are:
		#   info_hash, peer_id, port, uploaded, downloaded, left,    <-- REQUIRED
		#   compact, no_peer_id, event, ip, numwant, key, trackerid  <--- optional
		
		['info_hash', 'peer_id', 'port', 'uploaded', 'downloaded', 'left'].each do |i|
			if get_vars[i].nil? or get_vars[i] == ''
				raise "#{i} was invalid. Dump: #{get_vars.inspect}"
			end
		end
		['port', 'uploaded', 'downloaded', 'left'].map do |i|
			begin
				get_vars[i] = Integer(get_vars[i])
			rescue ArgumentError
				raise "#{i} was invalid. Dump: #{get_vars.inspect}"
			end
		end

		info_hash = get_vars['info_hash']
		torrent = @torrents[info_hash]
		if torrent.nil?
			#resp.write({'failure reason' => 'This torrent does not exist'}.bencode)
			#return resp.finish
			@torrents[info_hash] = {:peers => {}}
			torrent = @torrents[info_hash]
		end

		peer_id = get_vars['peer_id']
		event = get_vars['event']
		peers = torrent[:peers]
		if (peer = peers[peer_id]).nil? # New peer
			if event != 'started'
				raise "You must start first"
			else
				peer = (peers[peer_id] = {:completed => false})
			end
		end

		if event == 'stopped' or event == 'paused'
			peers.delete(peer_id) # Remove him from the peers
		else # Update the IP Address/Port
			peer[:ip] = get_vars['ip'] ? get_vars['ip'] : req.env['REMOTE_ADDR']
			peer[:port] = get_vars['port']
			peer[:compact] = IPAddr.new(peer[:ip]).hton + [peer[:port]].pack('n') #Store this for speed
			
			peer[:uploaded] = get_vars['uploaded']
			peer[:downloaded] = get_vars['downloaded']
			peer[:left] = get_vars['left']
			peer[:completed] = (peer[:left] == 0 ? true : false)
			if event == 'completed' #increment snatch
			end
		end
		
		# Output now. Fields are:
		#   interval, complete, incomplete, peers (dict|bin) <--- REQUIRED
		#   min interval, tracker id, warning message        <--- optional

		no_complete = peers.select { |peer_id, a| a[:completed] }.count
		output = { 'interval' => 60,
					  'complete' => no_complete,
					  'incomplete' => peers.count - no_complete
		}

		if get_vars['compact'] == '1' # Binary string
			output['peers'] = peers.map { |peer_id, a| a[:compact] }.join('')
		else
			output['peers'] =  peers.map { |peer_id, a| { 'peer id' => peer_id, 'ip' => a[:ip], 'port' => a[:port] } }
		end

		resp.write(output.bencode)
		puts resp.inspect
		return resp.finish
  end
end

