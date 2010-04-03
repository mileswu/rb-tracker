require 'net/http'
require 'cgi'

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

def generate_random_file()
   return { :info_hash => random_byte_string(20) }
end

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
   hash[:event] = ["started", "stopped", "completed"][rand(3)]
   hash[:left] = rand(100000000)

   return hash
end

$no_files = 100000
$no_clients = 100000

puts "Initializing random data ..."

$files = Array.new($no_files) { generate_random_file() }
$clients = Array.new($no_clients) { generate_random_client() }

puts " done\n"

def make_request()
   file = $files[rand($no_files)]
   client = $clients[rand($no_clients)]
   status = generate_random_status()

   str = "/announce?" + file.merge(client).merge(status).to_url_params() + " HTTP/1.1"
   response = Net::HTTP::get("0.0.0.0", str, "6969")

   puts str
   p response
   puts ""

   return nil
end

while true
   make_request()
end
