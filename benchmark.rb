require 'net/http'
require 'cgi'
require 'mysql'

require 'config'

srand(0)

class Hash
   def to_url_params
      return self.map { |a, b|
         CGI::escape(a.to_s()) + "=" + CGI::escape(b.to_s())
      }.join("&")
   end
end

def random_byte_string(len)
   str = ""
   for i in 1..len
      str.concat(rand(256))
   end

   return str
end

class Benchmarker
   private

   def generate_random_client()
      hash = {}

      hash[:peer_id] = random_byte_string(20)
      hash[:port] = rand(10000) + 30000
      hash[:compact] = rand(2)
      hash[:numwant] = rand(4000)
      hash[:no_peer_id] = rand(2)

      return hash
   end

   def generate_random_status()
      hash = {}

      hash[:uploaded] = rand(100000000)
      hash[:downloaded] = rand(100000000)
      hash[:event] = ["started", "stopped", "completed"][0]
      hash[:left] = rand(100000000)

      return hash
   end

   public

   def initialize()
      @db = Mysql.real_connect('localhost', MYSQL_USER, MYSQL_PASS, MYSQL_DB)
      @db.reconnect = true

      print "Initializing random data ..."
      $stdout.flush()

      hashes = []
      @db.query("SELECT info_hash FROM torrents").each_hash do |h|
         hashes.push(h)
      end
      @files = hashes

      users = []
      @db.query("SELECT ID, torrent_pass FROM users_main").each_hash do |h|
         users.push(nil)
      end
      @clients = users.map { generate_random_client() }

      @no_files = @files.size()
      @no_clients = @clients.size()

      #puts " done!\n"
   end

   def make_request()
      file = @files[rand(@no_files)]
      client = @clients[rand(@no_clients)]
      status = generate_random_status()

      str = "/bl0kp8070f3hzxto49t2u5v7s5euim83/announce?" + file.merge(client).merge(status).to_url_params()

      #t0 = Time.now()
      begin
         response = Net::HTTP::get("0.0.0.0", str, "3000")
      rescue EOFError => err
         puts "Server hit EOF (no response)"
      end
      #t1 = Time.now()

      #print "Called:\n\t"
      #puts str
      #print "Received:\n\t"
      #p response
      #puts "in #{t1 - t0} seconds\n"

      return nil
   end

   def go()
      10000.times do |i|
	puts i if(i%500 == 0)
         make_request()
      end
   end
end

benchmarker = Benchmarker.new()

require 'benchmark'
puts Benchmark.measure { benchmarker.go() }
