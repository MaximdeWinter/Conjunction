-- Python's random for what has to come out the same as the app's (a check with a seeded random, e.g. qt_ref's
-- random.seed(1)): the Mersenne Twister as CPython's _random (init_by_array with the seed's 32-bit words,
-- genrand_uint32), getrandbits, choice (_randbelow by getrandbits with rejection), random (53 bits).
--   local r = PR.new(1)          random.seed(1);  r:choice(list), r:random(), r:randbelow(n), r:getrandbits(k)
-- Checked against Python: ingame/ref/pyrandom_check.py.
local PR = {}
PR.__index = PR
local N, MM = 624, 397

local function init_genrand(self, s)
  local mt = {}
  mt[0] = s & 0xffffffff
  for i = 1, N - 1 do
    mt[i] = (1812433253 * (mt[i - 1] ~ (mt[i - 1] >> 30)) + i) & 0xffffffff
  end
  self.mt, self.mti = mt, N
end

local function init_by_array(self, key)
  init_genrand(self, 19650218)
  local mt = self.mt
  local i, j = 1, 0
  local klen = #key
  for _ = 1, math.max(N, klen) do
    mt[i] = ((mt[i] ~ ((mt[i - 1] ~ (mt[i - 1] >> 30)) * 1664525)) + key[j + 1] + j) & 0xffffffff
    i, j = i + 1, j + 1
    if i >= N then mt[0] = mt[N - 1] i = 1 end
    if j >= klen then j = 0 end
  end
  for _ = 1, N - 1 do
    mt[i] = ((mt[i] ~ ((mt[i - 1] ~ (mt[i - 1] >> 30)) * 1566083941)) - i) & 0xffffffff
    i = i + 1
    if i >= N then mt[0] = mt[N - 1] i = 1 end
  end
  mt[0] = 0x80000000
end

-- random.seed(n) for an integer n: its absolute value's 32-bit words, the lowest first
function PR.new(seed)
  local self = setmetatable({}, PR)
  local n = math.abs(seed or 0)
  local key = {}
  repeat
    key[#key + 1] = n & 0xffffffff
    n = n >> 32
  until n == 0
  init_by_array(self, key)
  return self
end

function PR:uint32()
  local mt = self.mt
  if self.mti >= N then
    for kk = 0, N - 1 do
      local y = (mt[kk] & 0x80000000) | (mt[(kk + 1) % N] & 0x7fffffff)
      local v = mt[(kk + MM) % N] ~ (y >> 1)
      if y & 1 == 1 then v = v ~ 0x9908b0df end
      mt[kk] = v
    end
    self.mti = 0
  end
  local y = mt[self.mti]
  self.mti = self.mti + 1
  y = y ~ (y >> 11)
  y = y ~ ((y << 7) & 0x9d2c5680)
  y = y ~ ((y << 15) & 0xefc60000)
  y = y ~ (y >> 18)
  return y & 0xffffffff
end

-- getrandbits(k), k up to 64 (words from the lowest up, as CPython fills them)
function PR:getrandbits(k)
  if k <= 32 then return self:uint32() >> (32 - k) end
  local lo = self:uint32()
  local hi = self:uint32() >> (64 - k)
  return (hi << 32) | lo
end

local function bit_length(n)
  local k = 0
  while n > 0 do k = k + 1 n = n >> 1 end
  return k
end
function PR:randbelow(n)
  local k = bit_length(n)
  local r = self:getrandbits(k)
  while r >= n do r = self:getrandbits(k) end
  return r
end
function PR:choice(list) return list[self:randbelow(#list) + 1] end
-- random.random(): (a >> 5) * 2^26 + (b >> 6), over 2^53
function PR:random()
  local a, b = self:uint32() >> 5, self:uint32() >> 6
  return (a * 67108864.0 + b) * (1.0 / 9007199254740992.0)
end

-- (the check's: n values of one kind from a fresh seed - "bits" k, "choice" of a list of size k, "random")
function PR.sequence(seed, kind, n, k)
  local r, out = PR.new(seed), {}
  for i = 1, n do
    if kind == "bits" then out[i] = r:getrandbits(k)
    elseif kind == "choice" then
      local list = {}
      for j = 1, k do list[j] = j end
      out[i] = r:choice(list)
    else out[i] = r:random() end
  end
  return out
end

return PR
