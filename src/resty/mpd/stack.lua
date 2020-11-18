local stack = {}
stack.__index = stack

function stack.new()
  local self = {
    first = 1,
    last = 0,
    data = {}
  }
  setmetatable(self,stack)
  return self
end

function stack:length()
  return self.last - self.first + 1
end

-- insert at beginning
function stack:unshift(d)
  self.first = self.first - 1
  self.data[self.first] = d
end

-- remove from beginning
function stack:shift()
  local index = self.first
  local d = self.data[index]
  self.data[index] = nil
  self.first = self.first + 1
  return d
end

-- insert at end
function stack:push(d)
  self.last = self.last + 1
  self.data[self.last] = d
end

-- remove from end
function stack:pop()
  local index = self.last
  local d = self.data[index]
  self.data[index] = nil
  self.last = self.last - 1
  return d
end

-- returns the front of the stack without removing it
function stack:front()
  if self:length() == 0 then
    return nil
  end
  return self.data[self.first]
end

-- returns the end of the stack without removing it
function stack:rear()
  if self:length() == 0 then
    return nil
  end
  return self.data[self.last]
end

return stack
