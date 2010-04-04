require 'libs/bencode'
require 'ipaddr'
require 'json'
require 'mysql'
require 'memcached'
require 'config'
require 'base64'
require 'cgi'


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


	def simple_response(str)
		[200, {"Content-Encoding" => "text/plain"}, str]
	end

	def hton_ip(str)
		Socket.gethostbyname(str)[3]
	end

end

class Tracker
	include TrackerHelper

	def initialize
		Thread.abort_on_exception = true

		@db = Mysql.real_connect('localhost', MYSQL_USER, MYSQL_PASS, MYSQL_DB)
		@db.reconnect = true
		@cache = Memcached.new("localhost:11211")

		@mutex = Mutex.new

		@last_db_write = Time.now.to_i

		read_marshal
		sleep_loop(READ_DB_FREQUENCY, true) { @mutex.synchronize { read_db } }
		#sleep_loop(WRITE_MARSHALL_FREQUENCY) { @mutex.synchronize { write_marshal } }
		#sleep_loop(WRITE_MEMCACHED_FREQUENCY) { @mutex.synchronize { write_memcached } }@
		#sleep_loop(WRITE_DB_FREQUENCY) { @mutex.synchronize { write_db } }
	end
	
	def call(env)
		@mutex.synchronize do
			path = env['PATH_INFO']
			if(path[-9..-1] == '/announce') # format is /<passkey>/announce
				return announce(env)
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
		puts "Opening resume file"
		begin 
			f = File.open("resume-state.db", "r")
			resume = Marshal.load(f.read)
			@users = resume[:users]
			@torrents = resume[:torrents]
			puts "Success"
		rescue
			@users = {}
			@torrents = {}
			puts "None found"
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
					@users[p] = { :id => i["ID"], :delta_up => 0, :delta_down => 0 }
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
				@torrents[ih] = { :peers => {}, :id => i["ID"], :free => (i["FreeTorrent"] == '1'), :modified => true}
			else
				@torrents[ih][:free] = (i["FreeTorrent"] == '1')
			end
		end
		puts "--Torrent_merging: #{Time.now.to_f - t} second"
		(@torrents.keys - infohashes).each { |i| @torrents.delete(i) }
		puts "Fetching torrents took #{Time.now.to_f - t} seconds. #{@torrents.length} active torrents"
	end

	def write_memcached
		t = Time.now.to_f
		@torrents.each_value do |i|
			if i[:modified] == false # no point updating stuff when it's not changed 
				next
			end
			i[:modified] = false

			key = MEMCACHED_PREFIX + "tracker_torrents_" + i[:id]
			data = i[:peers]

			data.each_pair do |k, h| #Peer ids are binary, need to be base64'd
				data[Base64.b64encode(k)] = h #This can be made shorter by removing unnecessary stuff
				data.delete(k)
			end
			data = JSON.generate(data)

			@cache.set key, data, ANNOUNCE_INTERVAL*2 #To avoid edge issues with time. Since a torrent *must* have new info every announce, this ensures that the data will never expire out of memcache. THERE IS ONE EXCEPTION: if a torrent has no peers
		end
		puts "Memcached writes took #{Time.now.to_f - t} seconds."
	end

	def write_db
		# Record last time that we did a writ
		diff = Time.now - @last_db_write
		@last_db_write = Time.now.to_i

		t = Time.now.to_f
		#Update users stats first
		query = "INSERT INTO users_main (ID, Uploaded, Downloaded) VALUES\n"
		@users.each_value do |i|
			next if i[:delta_up] == 0 and i[:delta_down] == 0
			query += "('#{i[:id]}', '#{i[:delta_up]}', '#{i[:delta_down]}')\n"
			i[:delta_up] = 0
			i[:delta_down] = 0
		end
		query += "ON DUPLICATE KEY UPDATE Uploaded = Uploaded + VALUES(Uploaded), Downloaded = Downloaded + VALUES(Downloaded)"
		puts query
		@db.query(query)
		puts "Updating user stats took #{Time.now.to_f - t} seconds."

		t = Time.now.to_f
		#Update transfer_history
		query = "INSERT INTO transfer_history (uid, fid, uploaded, downloaded, connectable, seeding, seedtime) VALUES\n"
		@torrents.each_value do |i|
			i[:peers].each do |p|
				next if p[:modified] == false
				time_since_start = @last_db_write - p[:start_time]
				time = (diff < time_since_start) ? diff : time_since_start
				query += "('#{p[:id]}', '#{i[:id]}', '#{p[:delta_up]}', '#{p[:delta_down]}', '1', '#{p[:completed]}', '#{time}')\n"
			end
		end
		query += "ON DUPLICATE KEY UPDATE uploaded = uploaded + VALUES(uploaded), downloaded = downloaded + VALUES(downloaded), connectable = VALUES(connectable), seeding = VALUES(seeding), seedtime = seedtime + VALUES(seedtime)"
		puts query
		@db.query(query)
		puts "Updating transfer history took #{Time.now.to_f - t} seconds"
	end


	def announce(env)
		
		passkey = 'bl0kp8070f3hzxto49t2u5v7s5euim83'
		if passkey == ''
			return simple_response({'failure reason' => 'This is private. You need a passkey'}.bencode)
		elsif (user = @users[passkey]).nil?
			return simple_response({'failure reason' => 'Your passkey is invalid'}.bencode)
		end

		get_vars = {}

=begin
		key = ""
		data = ""
		flag = false
		env['QUERY_STRING'].each_byte do |i|
			if i == 38 # &
				get_vars[key] = data
				key = ""
				data = ""
				flag = false
			elsif i == 61 # =
				flag = true
			else
				if flag
					data << i
				else
					key << i
				end
			end
		end
		get_vars[key] = data
=end

		for i in env['QUERY_STRING'].split("&")
			s = i.split("=", 2)
			get_vars[s[0]] = s[1]
=begin
			puts i
			split_pos = 0
			i.each_with_index do |j, pos|
				puts j[pos]
				if j[pos] == 61 #ASCII for '='
					#split_pos = pos
					break
				end
			end
			get_vars[i[0..split_pos-1]] = i[split_pos..-1]
=end
		end
		
		get_vars['info_hash'] = CGI::unescape(get_vars['info_hash'])
		get_vars['peer_id'] = CGI::unescape(get_vars['peer_id'])
		
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
		torrent[:modified] = true # flags it for the memcache route

		peer_id = get_vars['peer_id']
		event = get_vars['event']
		peers = torrent[:peers]
		if (peer = peers[peer_id]).nil? # New peer
			if event != 'started'
				raise "You must start first"
			else
				peer = (peers[peer_id] = {:id => user[:id], :completed => false, :start_time => Time.now.to_i, :delta_up => 0, :delta_down => 0, :uploaded => get_vars['uploaded'], :downloaded => get_vars['downloaded']})
			end
		end
		peer[:modified] = true

		if event == 'stopped' or event == 'paused'
			peers.delete(peer_id) # Remove him from the peers !!!MASSIVE. This can cause loss of stats!!!
		else # Update the IP Address/Port
			peer[:ip] = get_vars['ip'] ? get_vars['ip'] : env['REMOTE_ADDR']
			peer[:port] = get_vars['port']
			peer[:compact] = hton_ip(peer[:ip]) + [peer[:port]].pack('n') #Store this for speed
			
			peer[:last_announce] = Time.now.to_i

			peer[:delta_up] += peer[:uploaded] - get_vars['uploaded']
			peer[:delta_down] += peer[:downloaded] - get_vars['downloaded']

			user[:delta_up] += peer[:delta_up] # Update users stats
			user[:delta_down] += peer[:delta_down]

			peer[:uploaded] = get_vars['uploaded'] # Update transfer_history
			peer[:downloaded] = get_vars['downloaded']

			peer[:left] = get_vars['left']
			peer[:completed] = (peer[:left] == 0 ? true : false)
			if event == 'completed' #increment snatch
				snatched_completed(torrent[:id], user[:id])
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

		return simple_response(output.bencode)
	end

	def snatched_completed(tid, uid)
		#@db.query("INSERT INTO xbt_snatched (uid, tstamp, fid) VALUES('#{uid}', '#{Time.now.to_i}', '#{tid}')")
	end
end

