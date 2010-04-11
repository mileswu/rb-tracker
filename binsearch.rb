class SortedList
   def initialize(ls)
      @ls = ls.sort
   end

   def include?(a)
      l = 0
      r = @ls.size

      while(r - l > 1)
         m = (l+r)/2
         if(@ls[m] == a)
            return true
         elsif(@ls[m] > a)
            r = m
         else
            l = m
         end
      end

      return (@ls[l] == a)
   end
end
