
--- Build back-end for xmake-based modules.
local xmake = {}

local fs      = require("luarocks.fs")
local util    = require("luarocks.util")
local dir     = require("luarocks.dir")
local path    = require("luarocks.path")
local builtin = require("luarocks.build.builtin")
local cfg_ok, cfg = pcall(require, "luarocks.core.cfg")
if not cfg_ok then
    cfg = require("luarocks.cfg")
end

-- patch util.matchquote for luarocks 2.x
if not util.matchquote then
    function util.matchquote(s)
       return (s:gsub("[?%-+*%[%].%%()$^]","%%%1"))
    end
end

-- get host and arch
local function get_host_arch()
    local raw_os_name, raw_arch_name = '', ''
    local popen_status, popen_result = pcall(io.popen, "")
    if popen_status then
        popen_result:close()
        raw_os_name = io.popen('uname -s','r'):read('*l')
        raw_arch_name = io.popen('uname -m','r'):read('*l')
    else
        local env_OS = os.getenv('OS')
        local env_ARCH = os.getenv('PROCESSOR_ARCHITECTURE')
        if env_OS and env_ARCH then
            raw_os_name, raw_arch_name = env_OS, env_ARCH
        end
    end
    raw_os_name = (raw_os_name):lower()
    raw_arch_name = (raw_arch_name):lower()

    local os_patterns = {
        ['windows'] = 'windows',
        ['linux'] = 'linux',
        ['mac'] = 'macosx',
        ['darwin'] = 'macosx',
        ['^mingw'] = 'mingw',
        ['^cygwin'] = 'windows',
        ['bsd$'] = 'bsd',
        ['SunOS'] = 'solaris',
    }

    local arch_patterns = {
        ['^x86$'] = 'x86',
        ['i[%d]86'] = 'x86',
        ['amd64'] = 'x86_64',
        ['x86_64'] = 'x86_64',
        ['Power Macintosh'] = 'powerpc',
        ['^arm'] = 'arm',
        ['^mips'] = 'mips',
    }

    local os_name, arch_name = 'unknown', 'unknown'
    for pattern, name in pairs(os_patterns) do
        if raw_os_name:match(pattern) then
            os_name = name
            break
        end
    end
    for pattern, name in pairs(arch_patterns) do
        if raw_arch_name:match(pattern) then
            arch_name = name
            break
        end
    end
    return os_name, arch_name
end

-- patch cfg.is_platform for luarocks 2.x
if not cfg.is_platform then
    function cfg.is_platform(plat)
        local os_name = get_host_arch()
        return os_name == plat
    end
end

-- From builtin.autoextract_libs
local function autoextract_libs(external_dependencies, variables)
   if not external_dependencies then
      return nil, nil, nil
   end
   local libs = {}
   local incdirs = {}
   local libdirs = {}
   for name, data in pairs(external_dependencies) do
      if data.library then
         table.insert(libs, data.library)
         table.insert(incdirs, variables[name .. "_INCDIR"])
         table.insert(libdirs, variables[name .. "_LIBDIR"])
      end
   end
   return libs, incdirs, libdirs
end

-- Add platform configuration
local function add_platform_configs(info, rockspec, name)

   -- Get variables
   local variables = rockspec.variables
   local XMAKE_PLAT = variables.XMAKE_PLAT or os.getenv("XMAKE_PLAT")

   -- Add lua library
   info.incdirs   = info.incdirs or {}
   info.libdirs   = info.libdirs or {}
   info.libraries = info.libraries or {}
   info._cflags   = info._cflags or {}
   info._shflags  = info._shflags or {}
   info._syslinks = info._syslinks or {}
   if not XMAKE_PLAT then
      table.insert(info._cflags, variables.CFLAGS)
      table.insert(info._shflags, variables.LIBFLAG)
   end

   -- Add platform configuration
   if XMAKE_PLAT == "mingw" or cfg.is_platform("mingw") then
      table.insert(info._syslinks, variables.MSVCRT or "m")
   elseif cfg.is_platform("windows") then
      local exported_name = name:gsub("%.", "_")
      exported_name = exported_name:match('^[^%-]+%-(.+)$') or exported_name
      table.insert(info._shflags, "/export:" .. "luaopen_"..exported_name)
   end
   print("LUA_INCDIR2", variables.LUA_INCDIR)
end

-- Generate xmake.lua from builtin source files
local function autogen_xmakefile(xmakefile, rockspec)

   -- Patch build
   local build = rockspec.build
   if not build.modules then
      if rockspec.format_is_at_least and rockspec:format_is_at_least("3.0") then
         local libs, incdirs, libdirs = autoextract_libs(rockspec.external_dependencies, rockspec.variables)
         local install, copy_directories
         build.modules, install, copy_directories = builtin.autodetect_modules(libs, incdirs, libdirs)
         build.install = build.install or install
         build.copy_directories = build.copy_directories or copy_directories
      else
         return nil, "Missing build.modules table"
      end
   end

   -- Check lua.h
   local variables = rockspec.variables
   local lua_incdir, lua_h = variables.LUA_INCDIR, "lua.h"
   if not fs.exists(dir.path(lua_incdir, lua_h)) then
      return nil, "Lua header file " .. lua_h .. " not found (looked in " .. lua_incdir .. "). \n"  .. 
                  "You need to install the Lua development package for your system."
   end

   -- Generate xmake.lua
   local XMAKE_PLAT = variables.XMAKE_PLAT or os.getenv("XMAKE_PLAT")
   local build_sources = false
   local file = assert(io.open(xmakefile, "w"))
   file:write('add_rules("mode.release", "mode.debug")\n')
   for name, info in pairs(build.modules) do
      if type(info) == "string" then
         local ext = info:match("%.([^.]+)$")
         if ext ~= "lua" then
            info = {info}
         end
      end
      if type(info) == "table" then
         local sources = info.sources
         if info[1] then sources = info end
         if type(sources) == "string" then sources = {sources} end
         if #sources > 0 then
             build_sources = true
             local module_name = name:match("([^.]*)$") .. "." .. util.matchquote(cfg.lib_extension)
             file:write('target("' .. name .. '")\n')
             if not XMAKE_PLAT and cfg.is_platform("macosx") then
                file:write('    set_kind("binary")\n')
             else
                file:write('    set_kind("shared")\n')
             end
             file:write('    set_symbols("none")\n')
             file:write('    set_filename("' .. module_name .. '")\n')
             add_platform_configs(info, rockspec, name)
             for _, source in ipairs(sources) do
                file:write("    add_files('" .. source .. "')\n")
             end
             if info.defines then
                for _, define in ipairs(info.defines) do
                   file:write("    add_defines('" .. define .. "')\n")
                end
             end
             if info.incdirs then
                for _, incdir in ipairs(info.incdirs) do
                   file:write("    add_includedirs('" .. incdir .. "')\n")
                end
             end
             if info.libdirs then
                for _, libdir in ipairs(info.libdirs) do
                   file:write("    add_linkdirs('" .. libdir .. "')\n")
                   if not cfg.is_platform("windows") and not cfg.is_platform("mingw") and cfg.gcc_rpath then
                      file:write("    add_rpathdirs('" .. libdir .. "')\n")
                   end
                end
             end
             if info._cflags then
                for _, cflag in ipairs(info._cflags) do
                   file:write("    add_cflags('" .. cflag .. "', {force = true})\n")
                end
             end
             if info._shflags then
                for _, shflag in ipairs(info._shflags) do
                   if cfg.is_platform("macosx") then
                      file:write("    add_ldflags('" .. shflag .. "', {force = true})\n")
                   else
                      file:write("    add_shflags('" .. shflag .. "', {force = true})\n")
                   end
                end
             end
             if info.libraries then
                for _, library in ipairs(info.libraries) do
                   file:write("    add_links('" .. library .. "')\n")
                end
             end
             if info._syslinks then
                for _, link in ipairs(info._syslinks) do
                   file:write("    add_syslinks('" .. link .. "')\n")
                end
             end
             -- Install modules, e.g. socket.core -> lib/socket/core.so
             file:write("    on_install(function (target)\n")
             file:write("        local moduledir = path.directory((target:name():gsub('%.', '/')))\n")
             file:write("        import('target.action.install')(target, {libdir = path.join('lib', moduledir), bindir = path.join('lib', moduledir)})\n")
             file:write("    end)\n")
             file:write('\n')
         end
      end
   end
   file:close()
   if not build_sources then
     os.remove(xmakefile)
   end
   return true
end

-- Get xmake configuration arguments
local function xmake_config_args(rockspec, build_variables)

   local args = ""
   local variables                 = rockspec.variables
   local XMAKE_PLAT                = build_variables.XMAKE_PLAT or os.getenv("XMAKE_PLAT")
   local XMAKE_ARCH                = build_variables.XMAKE_ARCH or os.getenv("XMAKE_ARCH")
   local XMAKE_MODE                = build_variables.XMAKE_ARCH or os.getenv("XMAKE_MODE")
   local XMAKE_SDK                 = build_variables.XMAKE_SDK or os.getenv("XMAKE_SDK")
   local XMAKE_MINGW               = build_variables.XMAKE_MINGW or os.getenv("XMAKE_MINGW")
   local XMAKE_TOOLCHAIN           = build_variables.XMAKE_TOOLCHAIN or os.getenv("XMAKE_TOOLCHAIN")
   local XMAKE_CC                  = build_variables.XMAKE_CC or os.getenv("XMAKE_CC")
   local XMAKE_LD                  = build_variables.XMAKE_LD or os.getenv("XMAKE_LD")
   local XMAKE_CFLAGS              = build_variables.XMAKE_CFLAGS or os.getenv("XMAKE_CFLAGS")
   local XMAKE_LDFLAGS             = build_variables.XMAKE_LDFLAGS or os.getenv("XMAKE_LDFLAGS")
   local XMAKE_VS                  = build_variables.XMAKE_VS or os.getenv("XMAKE_VS")
   local XMAKE_VS_SDKVER           = build_variables.XMAKE_VS_SDKVER or os.getenv("XMAKE_VS_SDKVER")
   local XMAKE_VS_RUNTIME          = build_variables.XMAKE_VS_RUNTIME or os.getenv("XMAKE_VS_RUNTIME")
   local XMAKE_VS_TOOLSET          = build_variables.XMAKE_VS_TOOLSET or os.getenv("XMAKE_VS_TOOLSET")
   local XMAKE_XCODE_TARGET_MINVER = build_variables.XMAKE_XCODE_TARGET_MINVER or os.getenv("XMAKE_XCODE_TARGET_MINVER")
   if cfg.verbose then
      args = args .. " -vD"
   end
   if XMAKE_PLAT then
      args = args .. " -p " .. XMAKE_PLAT
   elseif cfg.is_platform("mingw") then
      args = args .. " -p mingw"
   end
   if XMAKE_ARCH then
      args = args .. " -a " .. XMAKE_ARCH
   end
   if XMAKE_MODE then
      args = args .. " -m " .. XMAKE_MODE
   end
   if XMAKE_SDK then
      args = args .. " --sdk=" .. XMAKE_SDK
   end
   if XMAKE_MINGW then
      args = args .. " --mingw=" .. XMAKE_MINGW
   end
   if XMAKE_TOOLCHAIN then
      args = args .. " --toolchain=" .. XMAKE_TOOLCHAIN
   end
   if XMAKE_CC then
      args = args .. " --cc=" .. XMAKE_CC
   end
   if XMAKE_LD then
      args = args .. " --sh=" .. XMAKE_LD
   end
   if XMAKE_CFLAGS then
      args = args .. " --cxflags=" .. XMAKE_CFLAGS
   end
   if XMAKE_LDFLAGS then
      args = args .. " --shflags=" .. XMAKE_LDFLAGS
   end
   if XMAKE_LDFLAGS then
      args = args .. " --ldflags=" .. XMAKE_LDFLAGS
   end
   if XMAKE_VS then
      args = args .. " --vs=" .. XMAKE_VS
   end
   if XMAKE_VS_RUNTIME then
      args = args .. " --vs_runtime=" .. XMAKE_VS_RUNTIME
   end
   if XMAKE_VS_SDKVER then
      args = args .. " --vs_sdkver=" .. XMAKE_VS_SDKVER
   end
   if XMAKE_VS_TOOLSET then
      args = args .. " --vs_toolset=" .. XMAKE_VS_TOOLSET
   end
   if XMAKE_XCODE_TARGET_MINVER then
      args = args .. " --target_minver=" .. XMAKE_XCODE_TARGET_MINVER
   end
   -- add lua library
   if variables.LUA_INCDIR then
      args = args .. " --includedirs=" .. variables.LUA_INCDIR
   end
   if cfg.link_lua_explicitly or XMAKE_PLAT == "mingw" or cfg.is_platform("mingw") then
      if variables.LUA_LIBDIR then
         args = args .. " --linkdirs=" .. variables.LUA_LIBDIR
      end
      if variables.LUALIB then
         local lualib = variables.LUALIB
         if lualib:find("^lib", 1) then
            lualib = lualib:match("lib(.*)%..-")
         else
            lualib = lualib:match("(.*)%..-")
         end
         if lualib then
            args = args .. " --syslinks=" .. lualib
         end
      end
   end
   return args
end

--- Driver function for the "xmake" build back-end.
-- @param rockspec table: the loaded rockspec.
-- @return boolean or (nil, string): true if no errors occurred,
-- nil and an error message otherwise.
function xmake.run(rockspec, no_install)

   -- Get rockspec
   assert(not rockspec.type or rockspec:type() == "rockspec")
   local build = rockspec.build
   local build_variables = build.variables or {}
   util.variable_substitutions(build_variables, rockspec.variables)

   -- Check xmake
   local xmake = "xmake"
   if fs.is_tool_available then
       local ok, err_msg = fs.is_tool_available(xmake, "XMake")
       if not ok then
          return nil, err_msg
       end
   end

   -- If inline xmake is present create xmake.lua from it.
   local xmakefile = dir.path(fs.current_dir(), "xmake.lua")
   if type(build.xmake) == "string" then
      local file = assert(io.open(xmakefile, "w"))
      file:write(build.xmake)
      file:close()
   end

   -- Generate xmake.lua from builtin source files
   if not fs.is_file(xmakefile) then
      local ok, err_msg = autogen_xmakefile(xmakefile, rockspec)
      if not ok then
         return nil, err_msg
      end
   end

   -- We need not build it if xmake.lua not found (only install lua scripts)
   if not fs.is_file(xmakefile) then
      return true
   end

   -- Dump xmake.lua if be verbose mode
   if cfg.verbose then
      print(xmakefile)
      local file = io.open(xmakefile, "r")
      if file then
         print(file:read("*all"))
         file:close()
      end
   end

   -- Do configure
   local args = xmake_config_args(rockspec, build_variables)
   if not fs.execute_string(xmake .. " f --root -y" .. args) then
      return nil, "Failed configuring."
   end

   -- Do build and install
   local do_build, do_install
   if rockspec.format_is_at_least and rockspec:format_is_at_least("3.0") then
      do_build   = (build.build_pass   == nil) and true or build.build_pass
      do_install = (build.install_pass == nil) and true or build.install_pass
   else
      do_build = true
      do_install = true
   end

   if do_build then
      if not fs.execute_string(xmake .. " --root" .. (cfg.verbose and " -vD" or "")) then
         return nil, "Failed building."
      end
   end
   if do_install and not no_install then
      if not fs.execute_string(xmake .. " install --root -y -o output") then
         return nil, "Failed installing."
      end
   end

   local libdir = path.lib_dir(rockspec.name, rockspec.version)
   fs.copy_contents(dir.path("output", "lib"), libdir, "exec")

   return true
end

return xmake
