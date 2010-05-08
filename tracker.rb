require 'libs/bencode'
require 'ipaddr'
require 'json'
require 'mysql'
require 'config'
require 'base64'
require 'inline'


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

	inline do |builder|
	builder.c '
		VALUE quick_cgi_unescape(char * str, int length) {
			int i=0, j=0, temp2;
			char out[300], temp[2];
			for(i=0; i<length; i++) {
				if(str[i] == 37) {
					temp[0] = str[i+1];
					temp[1] = str[i+2];
					i += 2;
					sscanf(temp, "%x", &temp2);
					out[j] = temp2;
					j++;
				}
				else {
					out[j] = str[i];
					j++;
				}

			}
			return(rb_str_new(out, j));
		}


	'

		end
	#def quick_cgi_unescape(str) #This is precisely the same atm, but we can optimise
#		a = str.gsub(/((?:%[^%]{2})+)/n) do
#			[$1.delete("%")].pack('H*')
#		end
#	end

	inline do |builder|
		builder.c '_
			VALUE parse_get_vars(char *str, int len) {
				int i=0, flag = 0;
				char key[300], data[300];
				int key_i = 0, data_i = 0;
				VALUE rb_hash = rb_hash_new();

				for(i=0; i<len; i++) {
					if(str[i] == 38) {
						key[i] = 0; data[i] = 0;
						rb_hash_aset(rb_hash, rb_str_new(key, key_i), rb_str_new(data, data_i));
						key_i = 0; data_i = 0;
						flag = 0;
					}
					else if(str[i] == 61) {
						flag = 1;
					}
					else {
						if(flag == 1) {
							data[data_i] = str[i];
							data_i++;
						}
						else {
							key[key_i] = str[i];
							key_i++;
						}

					}
				}
				rb_hash_aset(rb_hash, rb_str_new(key, key_i), rb_str_new(data, data_i));
				return(rb_hash);

			}

		'
	end
end

class Tracker
	include TrackerHelper

	def initialize
		Thread.abort_on_exception = true

		@db = Mysql.real_connect('localhost', MYSQL_USER, MYSQL_PASS, MYSQL_DB)
		@db.reconnect = true

		@mutex = Mutex.new
		@start_time = Time.now

		read_marshal
		read_client_whitelists
		read_db
		clean_up2

		sleep_loop(READ_DB_FREQUENCY) { @mutex.synchronize { read_db } }
		sleep_loop(WRITE_MARSHALL_FREQUENCY) { @mutex.synchronize { write_marshal } }
		sleep_loop(WRITE_DB_FREQUENCY) { @mutex.synchronize { write_db } }
		sleep_loop(CLEAN_FREQUENCY) { @mutex.synchronize { clean_up } }
		sleep_loop(5*60) { @mutex.synchronize { read_client_whitelists } }
	end
	
	def call(env)
		@mutex.synchronize do
			path = env['PATH_INFO']
			if(path[-9..-1] == '/announce') # format is /<passkey>/announce
				return announce(env)
			elsif(path == '/stats')
				body = "Uptime: #{Time.now - @start_time}\n"
				body << "Number of users #{@users.count}\n"
				body << "Number of torrents #{@torrents.count}\n"

				peers = 0
				@torrents.each_value do |t|
					peers += t[:peers].count
				end
				body << "Peers: #{peers}\n"

				return [200, {'Content-Type' => 'text/plain'}, body]
			elsif(path == DEBUG_PATH)
				time = Time.now.to_f
				body = "Uptime: #{Time.now - @start_time}\n"
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

	def read_client_whitelists
		a = []
		results = @db.query("SELECT * from xbt_client_whitelist")
		results.each_hash do |i|
			a << i["peer_id"]
		end
		@client_whitelist = Regexp.new("^("+a.join("|")+")")
	end

	def read_users
		t = Time.now.to_f
		results = @db.query("SELECT ID, Enabled, torrent_pass, Slots, DownMultiplier, UpMultiplier FROM users_main")
		puts "--User_query_merging: #{Time.now.to_f - t} second"

		passkeys = []
		results.each_hash do |i|
			if i["Enabled"] == '1'
				p = i["torrent_pass"]
				passkeys << p
				if(@users[p].nil?)
					@users[p] = { :id => i["ID"], :delta_up => 0, :delta_down => 0, :delta_rawdl => 0, :delta_rawup => 0 }
				end
				@users[p][:slots] = i["Slots"].to_i
				@users[p][:downmultiplier] = i["DownMultiplier"].to_f
				@users[p][:upmultiplier] = i["UpMultiplier"].to_f
			end
		end

		puts "--User_merging: #{Time.now.to_f - t} second"
		(@users.keys - passkeys).each { |i| @users.delete(i) }
		
		results = @db.query("SELECT mod_setting FROM mod_core WHERE mod_option='global_freeleech'")
		results_r = results.fetch_row()
		if results_r
			@global_fl = results_r[0].to_i
		else
			puts "Assuming FL is off"
			@global_fl = 0
		end

		puts "Fetching users took #{Time.now.to_f - t} seconds. #{@users.length} active users"
	end
	
	def read_torrents
		t = Time.now.to_f
		results = @db.query("SELECT ID, info_hash, FreeTorrent, DownMultiplier, UpMultiplier FROM torrents")

		puts "--Torrent_query: #{Time.now.to_f - t} seconds"
		infohashes = []
		results.each_hash do |i|
			ih = i["info_hash"]
			infohashes << ih
			if(@torrents[ih].nil?)
				@torrents[ih] = { :peers => {}, :id => i["ID"], :modified => true, :delta_snatch => 0}
			end
			@torrents[ih][:downmultiplier] = i["DownMultiplier"].to_f
			@torrents[ih][:upmultiplier] = i["UpMultiplier"].to_f
		end
		puts "--Torrent_merging: #{Time.now.to_f - t} second"
		(@torrents.keys - infohashes).each { |i| @torrents.delete(i) }
		puts "Fetching torrents took #{Time.now.to_f - t} seconds. #{@torrents.length} active torrents"
	end

	def clean_up
		t = Time.now.to_f
		counter = 0
		query_values = []
		query_values2 = []
		@torrents.each_value do |i|
			i[:peers].each_pair do |k,p|
				if((t - p[:last_announce]) > 2*ANNOUNCE_INTERVAL) # 2 for leniency
					counter += 1
					query_values << "('#{p[:id]}', '#{i[:id]}', '#{p[:delta_up]}', '#{p[:delta_down]}', '1', '#{p[:completed] ? 1 : 0}', '#{p[:start_time]}', '#{p[:last_announce]}', '#{p[:delta_time]}', '0', '#{p[:delta_snatch]}', '#{p[:left]}')"
					query_values2 << "('#{p[:id]}', '#{i[:id]}', '#{Base64.encode64(k)}', '#{p[:start_time]}', '#{p[:ip]}', '#{p[:port]}')"
					i[:peers].delete(k)
					i[:modified] = true
				end
			end
		end
		query = "INSERT INTO transfer_history (uid, fid, uploaded, downloaded, connectable, seeding, starttime, last_announce, seedtime, active, snatched, remaining) VALUES\n"
		query += query_values.join(",\n")
		query += "\nON DUPLICATE KEY UPDATE uploaded = uploaded + VALUES(uploaded), downloaded = downloaded + VALUES(downloaded), connectable = VALUES(connectable), seeding = VALUES(seeding), seedtime = seedtime + VALUES(seedtime), last_announce = VALUES(last_announce), active = VALUES(active), snatched = snatched + VALUES(snatched), remaining = VALUES(remaining)"
		query2 = "INSERT INTO transfer_ips (uid, fid, peer_id, starttime, ip, port) VALUES \n"
		query2 += query_values2.join(",\n")
		query2 += "\nON DUPLICATE KEY UPDATE ip = VALUES(ip), port = VALUES(port)"
		puts "--Generation of query and cleaning took #{Time.now.to_f - t} seconds."
		if counter > 0
			#puts query
			@db.query(query)
			@db.query(query2)
		end
		puts "Updating cleaning stats took #{Time.now.to_f - t} seconds."
	end

	def clean_up2 #This if for dealing with stuff that somehow snuck in and wasn't taken account of by clean_up
		t = Time.now.to_i
		t2 = Time.now.to_f
		@db.query("UPDATE transfer_history SET active = '0' WHERE last_announce < #{t - 2*ANNOUNCE_INTERVAL}");
		puts "Cleaning2 took #{Time.now.to_f - t2} seconds."
	end

	def write_db
		t = Time.now.to_f
		#Update users stats first
		query_values = []
		counter = 0
		@users.each_value do |i|
			next if i[:delta_rawup] == 0 and i[:delta_rawdl] == 0
			#if i[:delta_up] >= 0 and i[:delta_down] >= 0 and i[:delta_rawdl] >= 0 and i[:delta_rawup] >= 0 # prevent -ve stats
				counter += 1
				query_values << "('#{i[:id]}', '#{i[:delta_up]}', '#{i[:delta_down]}', '#{i[:delta_rawdl]}', '#{i[:delta_rawup]}')"
			#else
			#	puts "SERIOUS CHEATING or a bug"
			#end
			i[:delta_up] = 0
			i[:delta_down] = 0
			i[:delta_rawdl] = 0
			i[:delta_rawup] = 0
		end
		query = "INSERT INTO users_main (ID, Uploaded, Downloaded, rawdl, rawup) VALUES\n"
		query += query_values.join(",\n")
		query += "\nON DUPLICATE KEY UPDATE Uploaded = Uploaded + VALUES(Uploaded), Downloaded = Downloaded + VALUES(Downloaded), rawdl = rawdl + VALUES(rawdl), rawup = rawup + VALUES(rawup)"
		puts "--Generation of query #{Time.now.to_f - t} seconds."
		if counter > 0
			@db.query(query)
		end
		puts "Updating user stats took #{Time.now.to_f - t} seconds."

		t = Time.now.to_f
		#Update transfer_history - and IPs 
		query_values = []
		query_values2 = []
		counter = 0
		@torrents.each_value do |i|
			i[:peers].each_pair do |k, p|
				next if p[:delta_up] == 0 and p[:delta_down] == 0 and p[:delta_time] == 0 and p[:force_update] != true and p[:delta_snatch] == 0
				counter += 1
				query_values << "('#{p[:id]}', '#{i[:id]}', '#{p[:delta_up]}', '#{p[:delta_down]}', '1', '#{p[:completed] ? 1 : 0}', '#{p[:start_time]}', '#{p[:last_announce]}', '#{p[:delta_time]}', '1', '#{p[:delta_snatch]}', '#{p[:left]}')"
				query_values2 << "('#{p[:id]}', '#{i[:id]}', '#{Base64.encode64(k)}', '#{p[:start_time]}', '#{p[:ip]}', '#{p[:port]}')"
				p[:delta_up] = 0
				p[:delta_down] = 0
				p[:delta_time] = 0
				p[:delta_snatch] = 0
				p[:force_update] = false
			end
		end
		query = "INSERT INTO transfer_history (uid, fid, uploaded, downloaded, connectable, seeding, starttime, last_announce, seedtime, active, snatched, remaining) VALUES\n"
		query += query_values.join(",\n")
		query += "\nON DUPLICATE KEY UPDATE uploaded = uploaded + VALUES(uploaded), downloaded = downloaded + VALUES(downloaded), connectable = VALUES(connectable), seeding = VALUES(seeding), seedtime = seedtime + VALUES(seedtime), last_announce = VALUES(last_announce), active = VALUES(active), snatched = snatched + VALUES(snatched), remaining = VALUES(remaining)"
		query2 = "INSERT INTO transfer_ips (uid, fid, peer_id, starttime, ip, port) VALUES \n"
		query2 += query_values2.join(",\n")
		query2 += "\nON DUPLICATE KEY UPDATE ip = VALUES(ip), port = VALUES(port)"
		puts "--Generation of query #{Time.now.to_f - t} seconds."
		if counter > 0
			#puts query
			@db.query(query)
			@db.query(query2)
		end
		puts "Updating transfer history took #{Time.now.to_f - t} seconds"
		
		
		t = Time.now.to_f
		#Update Torrents table for seed/peer/snatch numbers
		query_values = []
		counter = 0
		@torrents.each_value do |i|
			next if i[:modified] == false and i[:delta_snatch] == 0
			counter += 1
			no_complete = i[:peers].select { |peer_id, a| a[:completed] }.count
			leechers = i[:peers].count - no_complete
			query_values << "('#{i[:id]}', '#{i[:delta_snatch]}', '#{no_complete}', '#{leechers}')"
			i[:modified] = false
			i[:delta_snatch] = 0
		end
		query = "INSERT INTO torrents (ID, Snatched, Seeders, Leechers) VALUES\n"
		query += query_values.join(",\n")
		query += "\nON DUPLICATE KEY UPDATE Snatched = Snatched + VALUES(Snatched), Seeders = VALUES(Seeders), Leechers = VALUES(Leechers)"
		puts "--Generation of torrents query #{Time.now.to_f - t} seconds."
		if counter > 0
			#puts query
			@db.query(query)
		end
		puts "Updating torrents table took #{Time.now.to_f - t} seconds"
	end

	def announce(env)
		passkey = env['PATH_INFO'][1..-10]

		if passkey == ''
			return simple_response({'failure reason' => 'This is private. You need a passkey'}.bencode)
		elsif (user = @users[passkey]).nil?
			return simple_response({'failure reason' => 'Your passkey is invalid'}.bencode)
		end

		get_vars = {}

		get_vars = parse_get_vars(env['QUERY_STRING'], env['QUERY_STRING'].length)
		
		get_vars['info_hash'] = quick_cgi_unescape(get_vars['info_hash'],get_vars['info_hash'].length)
		get_vars['peer_id'] = quick_cgi_unescape(get_vars['peer_id'],get_vars['peer_id'].length)
		
		# GET requests of interest are:
		#   info_hash, peer_id, port, uploaded, downloaded, left,    <-- REQUIRED
		#   compact, no_peer_id, event, ip, numwant, key, trackerid  <--- optional
		

		info_hash = get_vars['info_hash']
		peer_id = get_vars['peer_id']
		port = get_vars['port']
		uploaded = get_vars['uploaded']
		downloaded = get_vars['downloaded']
		left = get_vars['left']
		if info_hash.nil? or info_hash == '' or peer_id.nil? or peer_id == '' or port.nil? or port == '' or uploaded.nil? or uploaded == '' or downloaded.nil? or downloaded == '' or left.nil? or left == ''
			return simple_response({'failure reason' => 'Invalid Request'}.bencode)
		end
		begin
			port = Integer(port)
			uploaded = Integer(uploaded)
			downloaded = Integer(downloaded)
			left = Integer(left)
		rescue ArgumentError
			return simple_response({'failure reason' => 'Invalid Request'}.bencode)
		end

		torrent = @torrents[info_hash]
		if torrent.nil?
			return simple_response({'failure reason' => 'This torrent does not exist'}.bencode)
		end

		if peer_id.match(@client_whitelist) == nil
			return simple_response({'failure reason' => 'This client is not approved'}.bencode)
		end

		event = get_vars['event']
		peers = torrent[:peers]
		t = Time.now.to_i
		if (peer = peers[peer_id]).nil? # New peer - screw being compliant
			#if event != 'started'
			#	raise "You must start first"
			#else
		puts user.inspect	
			# Check slot restrictions
			if user[:slots] != -1
				no_active = 0
				@torrents.each_value do |to|
					to[:peers].each_value do |p|
						no_active += 1 if p[:id] == user[:id] and p[:completed] == false #Leeching
					end
				end
				if no_active >= user[:slots]
					return simple_response({'failure reason' => "You don't have enough slots free. Stop something and wait an hour"}.bencode)
				end
			end
				
			peer = (peers[peer_id] = {:id => user[:id], :completed => false, :start_time => t, :delta_time => 0, :last_announce => t, :delta_up => 0, :delta_down => 0, :uploaded => uploaded, :downloaded => downloaded, :force_update => true, :delta_snatch => 0})
			torrent[:modified] = true # flags it for the DB update
		end

		if event == 'stopped' or event == 'paused'
			return simple_response("Come again...") #ignore it
			#peers.delete(peer_id) # Remove him from the peers !!!MASSIVE. This can cause loss of stats!!!
		else # Update the IP Address/Port
			peer[:ip] = get_vars['ip'] ? get_vars['ip'] : env[IPADDRKEY] 
			peer[:port] = port
			peer[:compact] = hton_ip(peer[:ip]) + [peer[:port]].pack('n') #Store this for speed
		
			if(left == 0)
				peer[:delta_time] += t - peer[:last_announce] # seed time
			end
			peer[:last_announce] = t

			ddup = uploaded - peer[:uploaded]
			dddown = downloaded - peer[:downloaded]
			if(ddup < 0 or dddown < 0)
				ddup = 0
				dddown =0
				puts "weird negative thingy again"
			end

			peer[:delta_up] += ddup
			peer[:delta_down] += dddown

			user[:delta_rawup] += ddup
			user[:delta_rawdl] += dddown
			user[:delta_up] += ddup*user[:upmultiplier]*torrent[:upmultiplier] # Update users stats
			user[:delta_down] += dddown*user[:downmultiplier]*torrent[:downmultiplier] if @global_fl != 1

			peer[:uploaded] = uploaded # Update transfer_history
			peer[:downloaded] = downloaded

			peer[:left] = left
			peer[:completed] = (left == 0 ? true : false)
			if event == 'completed' #increment snatch
				peer[:delta_snatch] += 1
				torrent[:delta_snatch] += 1
				@db.query("UPDATE transfer_history SET snatched_time = '#{t}' WHERE uid = '#{peer[:id]}' AND fid = '#{torrent[:id]}'")
			end
		end
		
		# Output now. Fields are:
		#   interval, complete, incomplete, peers (dict|bin) <--- REQUIRED
		#   min interval, tracker id, warning message        <--- optional

		no_complete = peers.select { |peer_id, a| a[:completed] }.count
		output = { 'interval' => ANNOUNCE_INTERVAL,
					  'complete' => no_complete,
					  'incomplete' => peers.count - no_complete,
					  'min interval' => MIN_INTERVAL
		}

		n = get_vars['numwant'].to_i
		if n < 0 or n > 50
			n = 50
		end

		if get_vars['compact'] == '1' # Binary string
			output['peers'] = peers.map { |peer_id, a| a[:compact] }.sort_by {rand}[0..(n-1)].join('')
		else
			output['peers'] =  peers.map { |peer_id, a| { 'peer id' => peer_id, 'ip' => a[:ip], 'port' => a[:port] } }.sort_by {rand}[0..(n-1)]
		end

	#	puts output.inspect
		return simple_response(output.bencode)
	end

end

