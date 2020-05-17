;; based on https://github.com/ers35/luastatic/
(local fennel (require :fennel))

(fn shellout [command]
  (let [f (io.popen command)
        stdout (f:read :*all)]
    (and (f:close) stdout)))

(fn execute [cmd]
  (match (os.execute cmd)
    0 true
    true true))

(fn string->c-hex-literal [characters]
  (let [hex []]
    (each [character (characters:gmatch ".")]
      (table.insert hex (: "0x%02x" :format (string.byte character))))
    (table.concat hex ", ")))

(local c1
       "#ifdef __cplusplus
extern \"C\" {
#endif
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#ifdef __cplusplus
}
#endif
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if LUA_VERSION_NUM == 501
  #define LUA_OK 0
#endif

/* Copied from lua.c */

static lua_State *globalL = NULL;

static void lstop (lua_State *L, lua_Debug *ar) {
  (void)ar;  /* unused arg. */
  lua_sethook(L, NULL, 0, 0);  /* reset hook */
  luaL_error(L, \"interrupted!\");
}

static void laction (int i) {
  signal(i, SIG_DFL); /* if another SIGINT happens, terminate process */
  lua_sethook(globalL, lstop, LUA_MASKCALL | LUA_MASKRET | LUA_MASKCOUNT, 1);
}

static void createargtable (lua_State *L, char **argv, int argc, int script) {
  int i, narg;
  if (script == argc) script = 0;  /* no script name? */
  narg = argc - (script + 1);  /* number of positive indices */
  lua_createtable(L, narg, script + 1);
  for (i = 0; i < argc; i++) {
    lua_pushstring(L, argv[i]);
    lua_rawseti(L, -2, i - script);
  }
  lua_setglobal(L, \"arg\");
}

static int msghandler (lua_State *L) {
  const char *msg = lua_tostring(L, 1);
  if (msg == NULL) {  /* is error object not a string? */
    if (luaL_callmeta(L, 1, \"__tostring\") &&  /* does it have a metamethod */
        lua_type(L, -1) == LUA_TSTRING)  /* that produces a string? */
      return 1;  /* that is the message */
    else
      msg = lua_pushfstring(L, \"(error object is a %s value)\",
                            luaL_typename(L, 1));
  }
  /* Call debug.traceback() instead of luaL_traceback() for Lua 5.1 compat. */
  lua_getglobal(L, \"debug\");
  lua_getfield(L, -1, \"traceback\");
  /* debug */
  lua_remove(L, -2);
  lua_pushstring(L, msg);
  /* original msg */
  lua_remove(L, -3);
  lua_pushinteger(L, 2);  /* skip this function and traceback */
  lua_call(L, 2, 1); /* call debug.traceback */
  return 1;  /* return the traceback */
}

static int docall (lua_State *L, int narg, int nres) {
  int status;
  int base = lua_gettop(L) - narg;  /* function index */
  lua_pushcfunction(L, msghandler);  /* push message handler */
  lua_insert(L, base);  /* put it under function and args */
  globalL = L;  /* to be available to 'laction' */
  signal(SIGINT, laction);  /* set C-signal handler */
  status = lua_pcall(L, narg, nres, base);
  signal(SIGINT, SIG_DFL); /* reset C-signal handler */
  lua_remove(L, base);  /* remove message handler from the stack */
  return status;
}

int main(int argc, char *argv[]) {
 lua_State *L = luaL_newstate();
 luaL_openlibs(L);
 createargtable(L, argv, argc, 0);

 static const unsigned char lua_loader_program[] = {
")

(local lua-loader "local args = {...}
local lua_bundle = args[1]

local function load_string(str, name)
  if _VERSION == \"Lua 5.1\" then
    return loadstring(str, name)
  else
    return load(str, name)
  end
end

local function lua_loader(name)
  local mod = lua_bundle[name] or lua_bundle[name .. \".init\"]
  if mod then
    if type(mod) == \"string\" then
      local chunk, errstr = load_string(mod, name)
      if chunk then
        return chunk
      else
        error(
          (\"error loading module '%%s' from luastatic bundle:\\n\\t%%s\"):
          format(name, errstr),
          0
        )
      end
    elseif type(mod) == \"function\" then
      return mod
    end
  else
    return (\"\\n\\tno module '%%s' in luastatic bundle\"):format(name)
  end
end
table.insert(package.loaders or package.searchers, 2, lua_loader)

local func = lua_loader(\"%s\")
if type(func) == \"function\" then
  func((unpack or table.unpack)(arg))
else
  error(func, 0)
end
")

(local c2 ",
};
  if(luaL_loadbuffer(L, (const char*)lua_loader_program,
                     sizeof(lua_loader_program), \"%s\") != LUA_OK) {
    fprintf(stderr, \"luaL_loadbuffer: %%s\\n\", lua_tostring(L, -1));
    lua_close(L);
    return 1;
  }

  /* lua_bundle */
  lua_newtable(L);
  static const unsigned char lua_require_1[] = {
")

(local c3 "
  if (docall(L, 1, LUA_MULTRET)) {
    const char *errmsg = lua_tostring(L, 1);
    if (errmsg) {
      fprintf(stderr, \"%s\\n\", errmsg);
    }
    lua_close(L);
    return 1;
  }
  lua_close(L);
  return 0;
}
")

(fn out-lua-source [filename]
  (let [f (assert (io.open filename :r))
        out []]
    (f:read :*line) ; strip shebang
    (var data (f:read 4096))
    (while data
      (table.insert out (.. (string->c-hex-literal data) ", "))
      (set data (f:read 4096)))
    (f:close)
    (table.concat out)))

(fn compile-fennel [filename options]
  (let [f (if (= filename "-")
              io.stdin
              (assert (io.open filename :rb)))
        lua-code (fennel.compileString (f:read :*a) options)]
    (f:close)
    lua-code))

(fn fennel->c [filename options]
  (let [basename (filename:gsub "(.*[\\/])(.*)" "%2")
        basename-noextension (or (basename:match "(.+)%.") basename)
        dotpath (-> filename
                    (: :gsub "^%.%/" "")
                    (: :gsub "[\\/]" "."))
        dotpath-noextension (or (dotpath:match "(.+)%.") dotpath)]
    (.. c1
        (string->c-hex-literal (lua-loader:format dotpath-noextension))
        (c2:format basename-noextension)
        (string->c-hex-literal (compile-fennel filename options))
        "\n  };\n  "
        "lua_pushlstring(L, (const char*)lua_require_1, sizeof(lua_require_1));"
        (: "  lua_setfield(L, -2, \"%s\");\n\n" :format dotpath-noextension)
        c3)))

(fn write-c [filename options]
  (let [out-filename (.. filename "_binary.c")
        f (assert (io.open out-filename "w+"))]
    (f:write (fennel->c filename options))
    (f:close)
    out-filename))

(fn compile-binary [lua-c-path executable-name static-lua lua-include-dir]
  (let [cc (or (os.getenv "CC") "cc")
        ;; http://lua-users.org/lists/lua-l/2009-05/msg00147.html
        (rdynamic binary-extension) (if (: (shellout (.. cc " -dumpmachine"))
                                           :match "mingw")
                                        (values "" ".exe")
                                        (values "-rdynamic" ""))
        executable-name (.. executable-name binary-extension)
        link-with-libdl? (match (-?> (shellout "uname -s") (: :match "%a+"))
                           :Linux true :Darwin true :SunOS true)
        compile-command [cc "-Os" ; optimize for size
                         lua-c-path
                         static-lua
                         rdynamic
                         "-lm"
                         (if link-with-libdl? "-ldl" "")
                         "-o" executable-name
                         "-I" lua-include-dir
                         (os.getenv "CC_OPTS")]]
    (when (os.getenv "DEBUG")
      (print :command (table.concat compile-command " ")))
    (if (execute (table.concat compile-command " "))
        (do (os.exit 0)
            (os.remove lua-c-path))
        (os.exit 1))))

(fn compile [filename executable-name static-lua lua-include-dir options]
  (compile-binary (write-c filename options) executable-name
                  static-lua lua-include-dir))

(local help (: "
Usage: %s --compile-binary FILE OUT STATIC_LUA_LIB LUA_INCLUDE_DIR

Compile a binary from your Fennel program. This functionality is very
experimental and subject to change in future versions!

Requires a C compiler, a copy of liblua, and Lua's dev headers. Implies
the --require-as-include option.

  FILE: the Fennel source being compiled.
  OUT: the name of the executable to generate
  STATIC_LUA_LIB: the path to the Lua library to use in the executable
  LUA_INCLUDE_DIR: the path to the directory of Lua C header files

For example, on a Debian system, to compile a file called program.fnl using
Lua 5.3, you would use this:

    $ %s --compile-binary program.fnl program \\
        /usr/lib/x86_64-linux-gnu/liblua5.3.a /usr/include/lua5.3

The program will be compiled to Lua, then compiled to C, then compiled to
machine code. You can set the CC environment variable to change the compiler
used (default: cc) or set CC_OPTS to pass in compiler options. For example
set CC_OPTS=-static to generate a binary with static linking.

This method is currently limited to programs which do not use any C libraries
and programs which do not transitively requiring Lua modules. Requiring a Lua
module directly will work, but requiring a Lua module which requires another
will fail." :format (. arg 0) (. arg 0)))

{: compile : help}
