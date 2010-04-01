require 'bencode'
require 'ipaddr'

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
		@users = {"bl0kp8070f3hzxto49t2u5v7s5euim83" => {}}
		@torrents = {"\224\327\326\322\2136\256\225\016\237\032\264x\344\356\372\343X>\230" => {:peers => {}}}
	end
	
	def call(env)
		req = Rack::Request.new(env)
		path = req.path
		if(path[-9..-1] == '/announce') # format is /<passkey>/announce
			return announce(req)
		else
			return [200, {'Content-Type' => 'text/plain'}, "WTF are you trying to do"]
		end
	end

	private

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
		
		info_hash = get_vars['info_hash']
		if (torrent = @torrents[info_hash]).nil?
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

		if event == 'stopped'
			peers.delete(peer_id) # Remove him from the peers
		else # Update the IP Address/Port
			peer[:ip] = get_vars['ip'] ? get_vars['ip'] : req.env['REMOTE_ADDR']
			peer[:port] = get_vars['port'].to_i

			peer[:uploaded] = get_vars['uploaded'].to_i
			peer[:downloaded] = get_vars['downloaded'].to_i
			peer[:left] = get_vars['left'].to_i
		end
	


		# Output now. Fields are:
		#   interval, complete, incomplete, peers (dict|bin) <--- REQUIRED
		#   min interval, tracker id, warning message        <--- optional

		no_complete = peers.select { |peer_id, a| a[:completed] }.count
		output = { 'interval' => 1800,
					  'complete' => no_complete,
					  'incomplete' => peers.count - no_complete
		}

		if get_vars['compact'] == '1' # Binary string
			output['peers'] = peers.map { |peer_id, a| IPAddr.new(a[:ip]).hton + [a[:port]].pack('n') }.join('')
		else
			output['peers'] =  peers.map { |peer_id, a| { 'peer id' => peer_id, 'ip' => a[:ip], 'port' => a[:port] } }
		end

		resp.write(output.bencode)
		#puts resp.inspect
		return resp.finish
  end
end

