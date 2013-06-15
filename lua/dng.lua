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
utilities for dealing with CHDK DNG images and headers
this is not a fully featured TIFF/TIFF-EP/DNG reader
]]
local m={}
local lbu=require'lbufutil'
--[[
bind the tiff header
--]]
m.header_fields = {
	'byte_order',
	'id',
	'ifd0'
}
-- "interesting" tags, i.e. those used in a CHDK dng
m.tags = {
}
m.tags_map = {
	NewSubfileType				=0xfe,
	SubfileType					=0xff,
	ImageWidth					=0x100,
	ImageLength					=0x101,
	BitsPerSample				=0x102,
	Compression					=0x103,
	PhotometricInterpretation	=0x106,
	ImageDescription			=0x10e,
	Make						=0x10f,
	Model						=0x110,
	StripOffsets				=0x111,
	Orientation					=0x112,
	SamplesPerPixel				=0x115,
	RowsPerStrip				=0x116,
	StripByteCounts				=0x117,
	PlanarConfiguration			=0x11c,
	Software					=0x131,
	DateTime					=0x132,
	Artist						=0x13b,

	SubIFDs						=0x14a,

	Copyright					=0x8298,
	ExifIFD						=0x8769, -- from CHDK dng source

	TIFF_EPStandardID			=0x9216,

	DNGVersion					=0xc612,
	DNGBackwardVersion			=0xc613,
	UniqueCameraModel			=0xc614,
	ColorMatrix1				=0xc621,
	AnalogBalance				=0xc627,
	AsShotNeutral				=0xc628,
	BaselineExposure			=0xc62a,
	BaselineNoise				=0xc62b,
	BaselineSharpness			=0xc62c,
	LinearResponseLimit			=0xc62e,
	LenseInfo					=0xc630,
	CalibrationIlluminant1		=0xc65a,

}

for k,v in pairs(m.tags_map) do
	m.tags[v] = k
end

m.tag_types = {
	{name='BYTE',size=1},
	{name='ASCII',size=1,string=true},
	{name='SHORT',size=2},
	{name='LONG',size=4},
	{name='RATIONAL',size=8,elsize=4,rational=true},
	{name='SBYTE',size=1,signed=true},
	{name='UNDEFINED',size=1},
	{name='SSHORT',size=2,signed=true},
	{name='SSLONG',size=4,signed=true},
	{name='SRATIONAL',size=8,elsize=4,signed=true,rational=true},
	{name='FLOAT',size=4,float=true},
	{name='DOUBLE',size=8,float=true},
}

local function init_tag_types()
	for i,t in pairs(m.tag_types) do
		-- element size for rational
		if not t.elsize then
			t.elsize = t.size
		end
		-- lbuf functions to get / set values
		local sfx = tostring(t.elsize*8)
		if t.signed then
			sfx = 'i'..sfx
		elseif t.float then -- TODO not actually implemented in lbuf
			sfx = 'f'..sfx
		else
			sfx = 'u'..sfx
		end
		-- will be nil if not supported in lbuf
		t.lb_get = lbuf['get_'..sfx]
		t.lb_set = lbuf['set_'..sfx]
	end
end
init_tag_types()

function m.bind_header(d)
	d:bind_u16('byte_order')
	d:bind_u16('id')
	d:bind_u32('ifd0')
end

local ifd_entry_methods = {
	tagname = function(self)
		local n = m.tags[self.tag]
		if n then
			return n
		end
		return string.format('unk_0x%04x',self.tag)
	end,
	type = function(self)
		local t = m.tag_types[self.type_id]
		if t then
			return t
		end
		return {name='unk',size=0} -- size is actually unknown
	end,
	is_inline = function(self)
		return (self.count * self:type().size <= 4)
	end,
	--[[
	get a numeric elements of a value
	for ASCII, bytes are returned
	for rational, numerator and denominator are retuned in an array
	--]]
	getel = function(self,index)
		if index >= self.count then
			return nil
		end
		local t = self:type()
		-- if type is unknown, can't know size, just return nil
		-- calling code could inspect valoff if desired
		if t.name == 'unk' then
			return nil
		end
		local v_off
		if self:is_inline() then
			v_off = self.off + 8 -- short tag + short type + long count
		else
			v_off = self.valoff
		end
		v_off = v_off + t.size*index
		if not t.lb_get then
			return nil
		end
		if t.rational then
			return {t.lb_get(self._lb,v_off,2)}
		end
		return t.lb_get(self._lb,v_off)
	end,
}
function m.bind_ifd_entry(d,ifd,i)
	local off = ifd.off + 2 + i*12 -- offset + entry count + index*sizeof(entry)
	local e=lbu.wrap(d._lb)
	util.extend_table(e,ifd_entry_methods)
	e.off = off
	e:bind_seek(off)
	e:bind_u16('tag')
	e:bind_u16('type_id')
	e:bind_u32('count')
	e:bind_u32('valoff')
	return e
end

function m.bind_ifds(d)
	d.ifds={}
	local ifd_off = d.ifd0
	repeat
		if ifd_off >= d._lb:len() then
			error('ifd outside of data')
		end
		local n_entries = d._lb:get_u16(ifd_off)
		local ifd = {off=ifd_off,n_entries=n_entries,entries={}}
		for i=0, n_entries-1 do
			local e = m.bind_ifd_entry(d,ifd,i)
			table.insert(ifd.entries,e)
			-- TODO SubIFDs
		end
		table.insert(d.ifds,ifd)
		ifd_off = d._lb:get_u32(ifd_off + n_entries * 12 + 2)
	until ifd_off == 0
end

local dng_methods={}
function dng_methods.print_info(self)
	for i,fname in ipairs(m.header_fields) do
		printf('%s 0x%x\n',fname,self[fname])
	end
	for i, ifd in ipairs(self.ifds) do 
		printf('ifd%d offset=0x%x entries=%d\n',i-1,ifd.off,ifd.n_entries)
		for j, e in ipairs(ifd.entries) do
			local vdesc = 'offset'
			if e:is_inline() then
				vdesc = ' value'
			end
			printf(' %-30s tag=0x%04x type=%-10s count=%07d %s=0x%08x\n',
						e:tagname(),
						e.tag,
						e:type().name,
						e.count,
						vdesc,
						e.valoff)
		end
	end
end

function m.load(filename)
	local lb,err=lbu.loadfile(filename)
	if not lb then
		return false, err
	end
	local d=lbu.wrap(lb)
	util.extend_table(d,dng_methods)
	m.bind_header(d)
	if d.byte_order ~= 0x4949 then
		if d.byte_order == 0x4d4d then
			return false, 'big endian unsupported'
		end
		return false, string.format('invalid byte order 0x%x',d.byte_order)
	end
	if d.id ~= 42 then
		return false, string.format('invalid id %d, expected 42',d.id)
	end
	m.bind_ifds(d)
	return d
end
return m
