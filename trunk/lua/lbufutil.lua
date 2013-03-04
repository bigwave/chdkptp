--[[
 Copyright (C) 2010-2011 <reyalp (at) gmail dot com>

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License version 2 as
  published by the Free Software Foundation.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
--]]
--[[
utilities for working with lbuf objects
]]
local lbu={}
--[[
load a file into an lbuf
returns lbuf or false,error
]]
function lbu.loadfile(name) 
	local f,err=io.open(name,'rb')
	if not f then
		return false, err
	end
	local s=f:read('*a')
	f:close()
	if not s then
		return false, 'read failed'
	end
	return lbuf.new(s)
end

--[[
wrap an lbuf in an lbu object
]]
function lbu.wrap(lb)
	local mt = {
		__index=function(t,k)
			local fields = rawget(t,'_fields')
			if fields[k] then		
				return fields[k]:get()
			end
		end,
		__newindex=function(t,k,v)
			local fields = rawget(t,'_fields')
			-- TODO not a field, just set it on the table (to allow adding custom methods etc)
			if not fields[k] then
				rawset(t,k,v)
				return
			end
			if not fields[k].set then		
				error(string.format('attempt to set read-only field "%s"',tostring(k)),2)
			end
			fields[k]:set(v)
		end,
	}
	local t={
		_lb = lb,
		_fields = {}, -- bound fields
		_bindpos = 0, -- default next bind offset
	}
	t._check_bind_name = function(name) 
		-- don't allow replacing methods / field
		if rawget(t,name) ~= nil then
			error(string.format('attempt to bind field or method name "%s"',tostring(name)),3)
		end
	end
	-- standard methods
	t.hexdump = function(self,off,len)
		if not off then
			off = 0
		end
		if not len then
			len = self._lb:len()
		end
		local s=self._lb:string(off+1,off+len) -- string uses 1 based offset
		return util.hexdump(s)
	end
	t.bind = function(self,name,get,set,len,off) 
		if type(off) == 'nil' then
			off =self._bindpos
		end
		if off < 0 or off + len > self._lb:len() then
			error('illegal offset')
		end
		self._check_bind_name(name)
		self._fields[name]={
			get=get,
			set=set,
			offset=off,
			len=len,
		}
		self._bindpos = off+len
	end
	--[[
	--set next bind pos, mimic lua seek
	--TODO not used / tested yet
	t.bind_seek = function(self,whence,offset)
		if type(offset) == 'nil' then
			if type(whence) == 'nil' then
				whence = 0
			end
			offset = whence
			whence = 'cur'
		end
		local newpos
		if whence == 'set' then
			newpos = offset
		elseif whence == 'cur' then
			newpos = self._bindpos + offset
		elseif whence == 'end' then
			newpos = self._lb:len() - 1 + offset
		end
		if newpos < 0 or newpos >= self._lb:len() then
			return false,'invalid pos'
		end
		return self._bindpos
	end
	--]]

	-- return a getter for an integer value
	local bind_int_get = function(vtype)
		mname = 'get_'..vtype
		if type(lbuf[mname]) ~= 'function' then
			error(string.format('invalid lbuf method "%s"',tostring(mname)))
		end
		return function(fld) return t._lb[mname](t._lb,fld.offset) end
	end
	local bind_int_set = function(vtype)
		mname = 'set_'..vtype
		if type(lbuf[mname]) ~= 'function' then
			error(string.format('invalid lbuf method "%s"',tostring(mname)))
		end
		return function(fld,val) return t._lb[mname](t._lb,fld.offset,val) end
	end
	-- set up integer bind methods
	-- TODO assumes 4 byte
	for i,vtype in ipairs({'i32','u32'}) do
		-- default read only
		t['bind_'..vtype] = function(self,name,off)
				self:bind(name,
					bind_int_get(vtype),
					nil,
					4,
					off) 
		end
		-- read/write
		t['bind_rw_'..vtype] = function(self,name,off)
				self:bind(name,
					bind_int_get(vtype),
					bind_int_set(vtype),
					4,
					off)
		end
	end
	-- fixed length string field, with anything past the first \0 ignored
	t.bind_sz = function(self,name,len,off)
		self:bind(name,
			function(fld) 
				local str=self._lb:string(fld.offset+1,fld.offset+fld.len)
				local s,e,v = string.find(str,'^([^%z]*)')
				return v
			end,
			nil,
			len,
			off) 
	end
	setmetatable(t,mt)
	return t
end
return lbu
