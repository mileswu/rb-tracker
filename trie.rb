class Trie
   
   def initialize()
      @this = false
      @childs = []
   end

   def contains_substring?(str, offset = 0)
      if(@this)
         return true
      elsif(str.size <= offset)
         return false
      elsif(@childs[str[offset].to_int].nil?)
         return false
      else
         return @childs[str[offset].to_int].contains_substring?(str, offset+1)
      end
   end

   def add(str, offset = 0)
      if(str.size == offset)
         @this = true
      else
         if(@childs[str[offset].to_int].nil?)
            @childs[str[offset].to_int] = Trie.new
         end

         @childs[str[offset].to_int].add(str, offset+1)
      end
   end
end
