require 'net/http'
require 'cgi'
require 'mysql'
require 'pp'

require 'config'
require 'priority-queue'

srand(0)

class Hash
   def to_url_params
      return self.map { |a, b|
         CGI::escape(a.to_s()) + "=" + CGI::escape(b.to_s())
      }.join("&")
   end
end

class Object
   def iv_hash
      hash = {}
      for i in self.instance_variables
         hash[i[1..-1].to_sym] = self.instance_variable_get(i.to_sym)
      end

      return hash
   end
end

def random_byte_string(len)
   str = ""
   for i in 1..len
      str.concat(rand(256))
   end

   return str
end

class Client
   def initialize()
      @peer_id = random_byte_string(20)
      @port = rand(10000) + 30000
      @compact = rand(2)
      @numwant = rand(4000)
      @no_peer_id = rand(2)
   end
end

class Torrent
   attr_reader :info_hash, :putative_size

   def initialize(str)
      @info_hash = str
      @putative_size = rand(100000000)
   end

   def self.from_db(db)
      torrents = []

      db.query("SELECT info_hash FROM torrents").each_hash do |h|
         str = h["info_hash"]
         if(str && str.size == 20)
            torrents.push(self.new(str))
         end
      end

      return torrents
   end
end

class ClientTorrent
   attr_reader :time_due

   def initialize(client, torrent)
      @client = client
      @torrent = torrent

      @time_due = rand(30*60)
      @uploaded = rand(@torrent.putative_size())
      @downloaded = rand(@torrent.putative_size())
   end

   def step()
      @time_due += 25*60 + rand(10*60)
      
      # With probability 1/5, something happened
      if(rand() < 0.1)
         s = @torrent.putative_size
         @uploaded = [@uploaded + rand(s/20), s].min
         @downloaded = [@downloaded + rand(s/20), s].min
      end
   end

   def big_hash()
      hsh = @client.iv_hash.merge(@torrent.iv_hash)
      hsh[:uploaded] = @uploaded
      hsh[:downloaded] = @downloaded
      hsh[:left] = @torrent.putative_size - @downloaded

		return hsh
   end

   def make_request()
      str = "/bl0kp8070f3hzxto49t2u5v7s5euim83/announce?" + big_hash.to_url_params()

      begin
         response = Net::HTTP::get("0.0.0.0", str, "3000")
      rescue EOFError => err
         puts "Server hit EOF (no response)"
      end

      return nil
   end

	def <=>(other)
		return self.time_due <=> other.time_due
	end

	include Comparable
end

class Simulator
   public

   def initialize()
      @db = Mysql.real_connect('localhost', MYSQL_USER, MYSQL_PASS, MYSQL_DB)
      @db.reconnect = true
		print "DB is #{@db}\n"

      print "Initializing random data ..."
      $stdout.flush()

      @queue = PriorityQueue.new

      Torrent.from_db(@db).each do |t|
         c = Client.new
         ct = ClientTorrent.new(c, t)
         @queue.insert(ct)
      end
      print "done\n"
      print "There are #{@queue.size} Client / Torrent pairs\n"

      @start_time = Time.now
      print "The clock starts NOW = #{@start_time}"
   end

   def make_request()
      ct = @queue.remove_head()
      
      t = Time.now
		delay = ct.time_due - (t - @start_time)
		if(delay > 0)
			sleep(delay)
		end
      ct.make_request()

      ct.step()
      @queue.insert(ct)

      return nil
   end

   def go()
      10000.times do |i|
         puts i if(i%500 == 0)
         make_request()
      end
   end
end

simulator = Simulator.new()

require 'benchmark'
puts Benchmark.measure { simulator.go() }
