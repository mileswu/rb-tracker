class PriorityQueue
   private 

   def self.parent(ii)
      return ii / 2
   end

   def self.left_child(ii)
      return ii * 2
   end

   def self.right_child(ii)
      return ii * 2 + 1
   end


   def bubble_up(ii)
      pp = PriorityQueue.parent(ii)
      if(pp < 1 || @elts[ii] >= @elts[pp])
         return
      end

      temp = @elts[ii]
      @elts[ii] = @elts[pp]
      @elts[pp] = temp

      bubble_up(pp)
   end

   def bubble_down(ii)
      lc = PriorityQueue.left_child(ii)
      rc = PriorityQueue.right_child(ii)

      if((lc > size() or @elts[ii] < @elts[lc]) and (rc > size() or @elts[ii] < @elts[rc]))
         return
      end

      if(rc > size() or @elts[lc] < @elts[rc])
         jj = lc
      else
         jj = rc
      end

      temp = @elts[ii]
      @elts[ii] = @elts[jj]
      @elts[jj] = temp

      bubble_down(jj)
   end

   public

   attr_reader :size

   def initialize(arr = [])
      @elts = [nil]
      @elts.concat(arr)
      @size = arr.size()

      for ii in @size.downto(1)
         bubble_down(ii)
      end
   end

   def insert(a)
      @size += 1
      @elts[size()] = a

      bubble_up(size())
   end

   def head()
      return @elts[1]
   end

   def remove_head()
      a = @elts[1]
      if(a.nil?)
         return nil
      end

      @elts[1] = @elts[size()]
      @elts.pop()
      @size -= 1
      bubble_down(1)

      return a
   end
end
