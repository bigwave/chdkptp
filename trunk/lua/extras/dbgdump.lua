--[[
 Copyright (C) 2012-2013 <reyalp (at) gmail dot com>

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
module for displaying dumps generated by CHDK dbg_dump.c

usage
!m=require'extras/dbgdump'
!d=m.load('MY.DMP')
!d:print()
]]
local lbu=require'lbufutil'

local m = {}
m.meminfo_fields = {
	'start_address',
	'end_address',
	'total_size',
	'allocated_size',
	'allocated_peak',
	'allocated_count',
	'free_size',
	'free_block_max_size',
	'free_block_count',
}

m.meminfo_size = 4*#m.meminfo_fields

m.header_fields_v1 = {
	'ver',
	'time',
	'product_id',
	'romstart',
	'text_start',
	'data_start',
	'bss_start',
	'bss_end',
	'sp',
	'stack_count',
	'user_val',
	'user_data_len',
	'flags',
}

m.header_size_v1 = 4*#m.header_fields_v1

-- integer fields
m.header_fields_int_v2 = {
	'ver',
	'time',
	'tick',
	'product_id',
	'romstart',
	'uncached_bit',
	'max_ram_addr',
	'text_start',
	'data_start',
	'bss_start',
	'bss_end',
	'module_count',
	'module_info_size',
	'sp',
	'stack_count',
	'user_val',
	'user_data_len',
	'flags',
}
m.header_fields_v2 = util.extend_table({},m.header_fields_int_v2)
table.insert(m.header_fields_v2,'build_string')
m.header_size_v2 = 4*#m.header_fields_int_v2 + 100 -- size of build string
	
-- flat_hdr
m.flat_hdr_fields = {
	'magic',
	'rev',
	'entry',
	'data_start',
	'bss_start',
	'reloc_start',
	'import_start',
	'file_size',
	'module_info',
}

m.module_fields = { 
	'index',
	-- module_entry
	'hdr_ptr',
	'module_name',
	'hmod_ptr',
	unpack(m.flat_hdr_fields),
}

-- method for bound meminfo
local function print_meminfo(self)
	for _,name in ipairs(m.meminfo_fields) do
		local v=self[name]
		printf("%19s %11d 0x%08x\n",name,v,v)
	end
end

-- default printing for a bound lbu field
local function print_field(self,name)
	local v = self[name]
	if type(v) == 'number' then
		printf("%19s %11u 0x%08x\n",name,v,v)
	elseif type(v) == 'string' then
		printf("%19s %s\n",name,v)
	else 
		error('field "'..tostring(name).. '" has unexpected type: '..tostring(type(v)))
	end
end

local function bind_meminfo(d)
	-- additional lbu to allow d.foo.bar
	for j,mtype in ipairs({'mem','exmem'}) do
		local mi = lbu.wrap(d._lb)
		mi:bind_seek('set',d.header_size + (j-1)*m.meminfo_size)
		for i,fname in ipairs(m.meminfo_fields) do
			mi:bind_u32(fname)
		end
		mi.print = print_meminfo
		d[mtype] = mi
	end
	d.mem.is_heap_addr = function(self,v)
		-- 0xFFFFFFFF is meminfo not available case
		return (self.start_address ~= 0xFFFFFFFF and v >= self.start_address and v < self.end_address)
	end
	d.exmem.is_heap_addr = function(self,v)
		return (self.start_address ~= 0 and v >= self.start_address and v < self.end_address)
	end
end

local function annotate_arm_thumb(a)
	if a%2 ~= 0 then
		return '(thumb ?)'
	elseif a%4 == 0 then
		return '(arm ?)'
	end
	return ''
end
local module_methods = {}

function module_methods.print(self)
	for i,fname in ipairs(m.module_fields) do
		print_field(self,fname)
	end
	for i,fname in ipairs({'text','data','bss'}) do
		print_field(self,fname..'_addr')
	end
end

function module_methods.is_text_addr(self,a) 
	return a >= self.text_addr and a < self.data_addr
end

function module_methods.is_data_addr(self,a) 
	return a >= self.data_addr and a < self.bss_addr
end

function module_methods.is_bss_addr(self,a) 
	return a >= self.bss_addr and a < self.hdr_ptr + self.reloc_start
end

function module_methods.is_module_addr(self,a) 
	return a >= self.hdr_ptr and a < self.hdr_ptr + self.file_size
end

function module_methods.annotate_addr(self,a) 
	if not self:is_module_addr(a) then
		return ''
	end
	desc = self.module_name .. ': '
	if self:is_text_addr(a) then
		return desc .. 'text ' .. annotate_arm_thumb(a)
	end
	if self:is_data_addr(a) then
		return desc .. 'data'
	end
	if self:is_bss_addr(a) then
		return desc .. 'bss'
	end
	return desc .. 'unknown'
end

local function bind_modules(d)
	d.modules = {}
	d.modules_map = {}
	for i=1,d.module_count do
		local mi = lbu.wrap(d._lb)
		util.extend_table(mi,module_methods)
		mi:bind_seek('set',d.header_size +  m.meminfo_size * 2 + (i-1)*d.module_info_size)
		mi:bind_u32('index')
		mi:bind_u32('hdr_ptr')
		mi:bind_sz('module_name',12)
		mi:bind_u32('hmod_ptr')
		for j,fname in ipairs(m.flat_hdr_fields) do
			mi:bind_u32(fname)
		end
		mi.text_addr = mi.hdr_ptr + mi.entry
		mi.data_addr = mi.hdr_ptr + mi.data_start
		mi.bss_addr = mi.hdr_ptr + mi.bss_start
		d.modules[i]=mi
		d.modules_map[mi.module_name] = mi
	end
end
--[[
user data is always at the end
]]
local function init_udata(d)
	d.user_data_offset = d._lb:len() - d.user_data_len
end

--[[
common and version1 methods
--]]
local v1_methods = {}

-- stack functions
function v1_methods.stacki(self,i)
	return self._lb:get_i32(self.stack_offset + i*4)
end
function v1_methods.stacku(self,i)
	return self._lb:get_u32(self.stack_offset + i*4)
end
function v1_methods.is_stack_addr(self,v)
	-- TODO we don't know the actual stack size
	return (v >= self.sp and v <= self.sp+d.stack_count*4)
end

-- user data functions
function v1_methods.user_data_str(self) 
	return self._lb:string(-self.user_data_len,-1)
end
function v1_methods.udatai(self,i)
	return self._lb:get_i32(self.user_data_offset + i*4)
end
function v1_methods.udatau(self,i)
	return self._lb:get_u32(self.user_data_offset + i*4)
end

function v1_methods.print_header(self)
	printf("version %d\n",self.ver)
	printf("time %s (%d)\n",os.date('!%Y:%m:%d %H:%M:%S',self.time),self.time)
	for i=3,#self.header_fields do
		local name = self.header_fields[i]
		print_field(self,name)
	end
end

function v1_methods.annotate_addr(self,v)
	if v >= d.romstart then
		return 'ROM'
	end
	local desc
	if self.exmem:is_heap_addr(v) then
		desc = 'exmem heap'
	end
	if self.mem:is_heap_addr(v) then
		desc = 'heap'
	end
	if v >= self.text_start and v < self.data_start then
		desc = 'CHDK text ' .. annotate_arm_thumb(v)
	elseif v >= d.data_start and v < d.bss_start then
		desc = 'CHDK data'
	elseif v >= d.bss_start and v <= d.bss_end then
		desc = 'CHDK bss'
	elseif d:is_stack_addr(v) then
		 -- may not be accurate since we don't know full depth of stack
		desc = 'stack ?'
	else
		return ''
	end
	return desc
end

function v1_methods.print_stack(self)
	printf('stack:\n')
	for i=0,self.stack_count-1 do
		local v=self:stacku(i)
		if not v then
			printf("truncated dump at %d ?\n",i*4)
			break
		end
		printf('%04d 0x%08x: 0x%08x %11d %s\n',i*4,d.sp + i*4,v,v,self:annotate_addr(v))
	end
end

function v1_methods.print_udata_hex(self)
	if self.user_data_len > 0 then
		printf('user data:\n%s\n',util.hexdump(self:user_data_str(),self.user_val))
	end
end

function v1_methods.print_udata_words(self,start,count)
	if self.user_data_len == 0 then
		return
	end
	if type(start) == 'nil' then
		start = 0
	end
	local max = math.floor(self.user_data_len/4) - 1
	if start > max then
		util.warnf('start > max');
		return
	end
	if type(count) ~= 'nil' then
		if start + count <= max then
			max = start+count-1
		else
			util.warnf('start + count > max');
		end
	end
	for i=start,max do
		local v=self:udatau(i)
		printf('%04d: 0x%08x %11d %s\n',i*4,v,v,self:annotate_addr(v))
	end
end

function v1_methods.print_summary(self)
	self:print_header()
	printf("meminfo:\n")
	self.mem:print()
	printf("exmeminfo:\n")
	self.exmem:print()
end

function v1_methods.print(self)
	self:print_summary()
	self:print_stack()
	self:print_udata_hex()
end

function m.bind_v1(d)
	-- ver is always 1st field, already bound
	d.header_fields = m.header_fields_v1
	for i=2,#d.header_fields do
		d:bind_u32(d.header_fields[i])
	end
	util.extend_table(d,v1_methods)
	d.header_size = m.header_size_v1
	bind_meminfo(d)
	d.stack_offset = d.header_size + m.meminfo_size * 2
	init_udata(d)
end

local v2_methods = util.extend_table({},v1_methods)

function v2_methods.is_ram_addr(self,a)
	-- TODO could break out TCM etc
	return a >=0 and a <= self.max_ram_addr
end

function v2_methods.is_uncached_ram_addr(self,a)
	return a >=self.uncached_bit and a <= self.uncached_bit + self.max_ram_addr
end

function v2_methods.annotate_addr(self,a)
	local desc
	for i,mi in ipairs(self.modules) do
		desc = mi:annotate_addr(a)
		if desc ~= '' then
			return desc
		end
	end
	-- common 
	desc = v1_methods.annotate_addr(self,a)
	if desc ~= ''  then
		return desc
	end
	-- too many other common values match to be useful, !ram might be better
	--[[
	if self:is_ram_addr(a) then
		return 'RAM?'
	end
	if self:is_uncached_ram_addr(a) then
		return 'uncached RAM?'
	end
	]]
	return ''
end
function v2_methods.print_modules(self)
	for i,mi in ipairs(self.modules) do
		printf('module %d "%s"\n',i,mi.module_name)
		mi:print()
	end
end

function v2_methods.print_summary(self)
	v1_methods.print_summary(self)
	self:print_modules()
end

function m.bind_v2(d)
	d.header_fields = m.header_fields_v2
	for i=2,#m.header_fields_int_v2 do
		d:bind_u32(m.header_fields_int_v2[i])
	end
	d:bind_sz('build_string',100)
	util.extend_table(d,v2_methods)
	d.header_size = m.header_size_v2
	bind_meminfo(d)
	d.stack_offset = d.header_size + m.meminfo_size * 2 + d.module_count * d.module_info_size
	init_udata(d)
	bind_modules(d)
end

function m.load(name)
	local lb,err=lbu.loadfile(name)
	if not lb then
		return false, err
	end
	local d=lbu.wrap(lb)
	util.extend_table(d,dump_methods)
	d:bind_u32('ver')
	if d.ver == 1 then
		m.bind_v1(d)
	elseif d.ver == 2 then
		m.bind_v2(d)
	else
		return false, 'unknown version ' ..tostring(d.ver)
	end
	return d
end

return m
