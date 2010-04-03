require 'libs/bencode'
require 'ipaddr'
require 'json'
require 'mysql'
require 'memcached'
require 'config'
require 'base64'

class String
	def to_hex
		return self.unpack("H*")
	end
end

module TrackerHelper
	def sleep_loop(time, first=false, &block)
		if(first)
			t = Thread.new do
				while 1
					yield
					sleep time
				end
			end
			return t
		else
			t = Thread.new do
				while 1
					sleep time
					yield
				end
			end
			return t
		end
	end
end

class Tracker
	include TrackerHelper

	def initialize
		@db = Mysql.real_connect('localhost', MYSQL_USER, MYSQL_PASS, MYSQL_DB)
		@db.reconnect = true
		@cache = Memcached.new("localhost:11211")

		@mutex = Mutex.new

		read_marshal
		sleep_loop(30, true) { @mutex.synchronize { read_db } }
		sleep_loop(30) { @mutex.synchronize { write_marshal } }
	end
	
	def call(env)
		@mutex.synchronize do
			req = Rack::Request.new(env)
			path = req.path
			if(path[-9..-1] == '/announce') # format is /<passkey>/announce
				return announce(req)
			elsif(path == '/debug')
				time = Time.now.to_f
				body = ""
				for i in @users
					body << i.inspect + "\n"
				end
				body << "\n----------\n"
				for i in @torrents
					body << i.inspect + "\n"
				end
				puts "Debug generation took #{Time.now.to_f - time} seconds"

				return [200, {'Content-Type' => 'text/plain'}, body]
			else
				return [200, {'Content-Type' => 'text/plain'}, "WTF are you trying to do"]
			end
		end
	end

	private

	def read_marshal
		begin 
			f = File.open("resume-state.db", "r")
			resume = Marshal.load(f.read)
			@users = resume[:users]
			@torrents = resume[:torrents]
		rescue
			@users = {}
			@torrents = {}
		end
	end

	def write_marshal
		t = Time.now.to_f
		f = File.open("resume-state.db", "w")
		f.write(Marshal.dump({:users => @users, :torrents=> @torrents}))
		f.close
		puts "Marshal generation took #{Time.now.to_f - t} seconds"
	end

	def read_db
		read_users
		read_torrents
	end

	def read_users
		t = Time.now.to_f
		results = @db.query("SELECT ID, Enabled, torrent_pass FROM users_main")
		puts "--User_query_merging: #{Time.now.to_f - t} second"

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

		puts "--User_merging: #{Time.now.to_f - t} second"
		(@users.keys - passkeys).each { |i| @users.delete(i) }
		puts "Fetching users took #{Time.now.to_f - t} seconds. #{@users.length} active users"
	end
	
	def read_torrents
		t = Time.now.to_f
		results = @db.query("SELECT ID, info_hash, FreeTorrent FROM torrents")

		puts "--Torrent_query: #{Time.now.to_f - t} seconds"
		infohashes = []
		results.each_hash do |i|
			ih = i["info_hash"]
			infohashes << ih
			if(@torrents[ih].nil?)
				@torrents[ih] = { :peers => {}, :id => i["ID"], :marked => true, :free => (i["FreeTorrent"] == '1')}
			else
				@torrents[ih][:free] = (i["FreeTorrent"] == '1')
			end
		end
		puts "--Torrent_merging: #{Time.now.to_f - t} second"
		(@torrents.keys - infohashes).each { |i| @torrents.delete(i) }
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
			resp.write({'failure reason' => 'This torrent does not exist'}.bencode)
			return resp.finish
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
				snatched_completed(torrent[:id], @users[passkey][:id])
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

	def snatched_completed(tid, uid)
		@db.query("INSERT INTO xbt_snatched (uid, tstamp, fid) VALUES('#{uid}', '#{Time.now.to_i}', '#{tid}')")
	end
end

