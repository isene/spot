; ============================================================================
; spot — presenter spotlight overlay for the CHasm suite.
;
; MVP path (B): no RENDER, no ARGB visual. A solid dark-gray InputOutput
; window covers the root, override-redirect so no WM touches it. The hole
; that follows the cursor is cut with the SHAPE extension's bounding-region
; rectangles — four rects ("frame minus square") around a 2R×2R square at
; the cursor. Click-through is SHAPE input-region empty.
;
; This is goal-1 work: nothing runs until invoked; while running, redraws
; happen only on actual cursor motion ticks (≤30 Hz polled). Esc exits.
;
; Build: nasm -f elf64 spot.asm -o spot.o && ld spot.o -o spot
; ============================================================================

BITS 64
DEFAULT REL

; ---- Linux x86_64 syscalls -------------------------------------------------
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_POLL        7
%define SYS_EXIT        60
%define SYS_SOCKET      41
%define SYS_CONNECT     42

%define AF_UNIX         1
%define SOCK_STREAM     1
%define POLLIN          1

; ---- X11 opcodes -----------------------------------------------------------
%define X11_CREATE_WINDOW       1
%define X11_DESTROY_WINDOW      4
%define X11_MAP_WINDOW          8
%define X11_GRAB_KEY            33
%define X11_UNGRAB_KEY          34
%define X11_QUERY_POINTER       38
%define X11_QUERY_EXTENSION     98
%define ANY_MODIFIER            0x8000
%define X11_GET_KEYBOARD_MAPPING 101
%define XK_ESCAPE               0xFF1B
%define XK_Q                    0x71

%define EV_KEY_PRESS            2
%define EV_EXPOSE               12
%define EV_MAP_NOTIFY           19

%define CW_BACK_PIXEL           0x0002
%define CW_OVERRIDE_REDIRECT    0x0200
%define CW_EVENT_MASK           0x0800

%define EVMASK_KEY_PRESS        0x0001
%define EVMASK_EXPOSURE         0x8000
%define EVMASK_STRUCTURE        0x20000

%define INPUT_OUTPUT            1
%define COPY_FROM_PARENT        0

%define GRAB_MODE_ASYNC         1

; ---- SHAPE extension opcodes (minor) ---------------------------------------
%define SHAPE_RECTANGLES        1
%define SHAPE_KIND_BOUNDING     0
%define SHAPE_KIND_INPUT        2
%define SHAPE_SET               0
%define SHAPE_UNSORTED          0

; ---- Layout ----------------------------------------------------------------
%define SPOT_RADIUS             140       ; spotlight radius in px
%define DEFAULT_DIM             80        ; 0=white, 100=black; default ≈ #333333

; ============================================================================
; BSS
; ============================================================================
SECTION .bss
align 8

envp:                resq 1
xauth_buf:           resb 4096
xauth_data:          resb 32
xauth_len:           resq 1

x11_fd:              resq 1
x11_seq:             resd 1
x11_rid_base:        resd 1
x11_rid_mask:        resd 1
x11_rid_next:        resd 1
display_num:         resq 1

screen_w:            resw 1
screen_h:            resw 1
root_window:         resd 1
root_visual:         resd 1
root_depth:          resb 1
min_keycode:         resb 1
max_keycode:         resb 1
esc_keycode:         resb 1
q_keycode:           resb 1
alignb 4
overlay_win:         resd 1
shape_major:         resb 1
alignb 4
dim_pct:             resd 1            ; SPOT_DIM env value, 0-100
back_pixel:          resd 1            ; computed grayscale fill

cursor_x:            resw 1
cursor_y:            resw 1
last_x:              resw 1
last_y:              resw 1

; circle_hw[i] = floor(sqrt(R² - i²)), for i in 0..R inclusive
circle_hw:           resw SPOT_RADIUS + 1

sockaddr_buf:        resb 128
conn_setup_buf:      resb 32768
write_buf:           resb 65536
write_pos:           resq 1
read_buf:            resb 65536
tmp_buf:             resb 256
; bounds_buf holds the SHAPE_RECTANGLES request body. With ~280 rows
; producing 2 rects each plus 2 caps, worst case ≈ 16 + 564*8 ≈ 4.5 KB.
bounds_buf:          resb 8192

; ============================================================================
; RODATA
; ============================================================================
SECTION .rodata
x11_sock_pre:        db "/tmp/.X11-unix/X", 0
auth_name:           db "MIT-MAGIC-COOKIE-1"
auth_name_len equ $ - auth_name
shape_name:          db "SHAPE"
shape_name_len equ $ - shape_name

err_connect:         db "spot: X11 connect failed", 10
err_connect_len equ $ - err_connect
err_shape:           db "spot: SHAPE extension missing", 10
err_shape_len equ $ - err_shape

; ============================================================================
; TEXT
; ============================================================================
SECTION .text
global _start

_start:
    mov rax, [rsp]                  ; argc
    lea rcx, [rsp + 8 + rax*8 + 8]  ; envp
    mov [envp], rcx

    call parse_display
    call read_xauthority
    call parse_dim
    call build_circle_table
    call x11_connect
    test rax, rax
    js .die_connect
    call x11_parse_setup
    call query_shape
    cmp byte [shape_major], 0
    je .die_shape
    call query_keymap               ; resolve XK_Escape/XK_q → real keycodes

    call grab_keys                  ; passive Esc/q grab on root FIRST
    call create_overlay
    call set_input_passthrough
    call x11_flush
    call query_pointer_once
    call set_bounding_circle
    call x11_flush

    call event_loop
    call cleanup
    xor edi, edi
    mov rax, SYS_EXIT
    syscall

.die_connect:
    mov rsi, err_connect
    mov rdx, err_connect_len
    jmp .die
.die_shape:
    mov rsi, err_shape
    mov rdx, err_shape_len
.die:
    mov rax, SYS_WRITE
    mov rdi, 2
    syscall
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

; ============================================================================
; parse_display — read $DISPLAY, store integer in display_num.
; ============================================================================
parse_display:
    mov rcx, [envp]
.pd_loop:
    mov rdi, [rcx]
    test rdi, rdi
    jz .pd_default
    cmp dword [rdi], 'DISP'
    jne .pd_next
    cmp dword [rdi+4], 'LAY='
    jne .pd_next
    add rdi, 8
.pd_findcolon:
    movzx eax, byte [rdi]
    test al, al
    jz .pd_default
    cmp al, ':'
    je .pd_have_colon
    inc rdi
    jmp .pd_findcolon
.pd_have_colon:
    inc rdi
    xor eax, eax
.pd_digit:
    movzx edx, byte [rdi]
    sub edx, '0'
    cmp edx, 9
    ja .pd_save
    imul eax, eax, 10
    add eax, edx
    inc rdi
    jmp .pd_digit
.pd_save:
    mov [display_num], rax
    ret
.pd_next:
    add rcx, 8
    jmp .pd_loop
.pd_default:
    mov qword [display_num], 0
    ret

; ============================================================================
; read_xauthority — set xauth_data + xauth_len if MIT-MAGIC-COOKIE-1 found.
; ============================================================================
read_xauthority:
    push rbx
    push r12
    mov qword [xauth_len], 0
    mov rdi, [envp]
.rxa_loop:
    mov rax, [rdi]
    test rax, rax
    jz .rxa_try_home
    cmp dword [rax], 'XAUT'
    jne .rxa_next
    cmp dword [rax+4], 'HORI'
    jne .rxa_next
    cmp word  [rax+8], 'TY'
    jne .rxa_next
    cmp byte  [rax+10], '='
    jne .rxa_next
    lea rsi, [rax + 11]
    jmp .rxa_open
.rxa_next:
    add rdi, 8
    jmp .rxa_loop
.rxa_try_home:
    mov rdi, [envp]
.rxa_home_loop:
    mov rax, [rdi]
    test rax, rax
    jz .rxa_done
    cmp dword [rax], 'HOME'
    jne .rxa_home_next
    cmp byte [rax+4], '='
    jne .rxa_home_next
    lea rsi, [rax + 5]
    lea rdi, [tmp_buf]
.rxa_cp_home:
    mov al, [rsi]
    test al, al
    jz .rxa_append
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .rxa_cp_home
.rxa_append:
    mov dword [rdi], '/.Xa'
    mov dword [rdi+4], 'utho'
    mov dword [rdi+8], 'rity'
    mov byte  [rdi+12], 0
    lea rsi, [tmp_buf]
    jmp .rxa_open
.rxa_home_next:
    add rdi, 8
    jmp .rxa_home_loop
.rxa_open:
    mov rax, SYS_OPEN
    mov rdi, rsi
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .rxa_done
    mov rbx, rax
    mov rax, SYS_READ
    mov rdi, rbx
    lea rsi, [xauth_buf]
    mov rdx, 4096
    syscall
    mov r12, rax
    mov rax, SYS_CLOSE
    mov rdi, rbx
    syscall
    lea rsi, [xauth_buf]
    lea rdi, [xauth_buf]
    add rdi, r12
.rxa_parse:
    cmp rsi, rdi
    jge .rxa_done
    add rsi, 2
    movzx eax, byte [rsi]
    shl eax, 8
    movzx ecx, byte [rsi+1]
    or eax, ecx
    add rsi, 2
    add rsi, rax
    movzx eax, byte [rsi]
    shl eax, 8
    movzx ecx, byte [rsi+1]
    or eax, ecx
    add rsi, 2
    add rsi, rax
    movzx eax, byte [rsi]
    shl eax, 8
    movzx ecx, byte [rsi+1]
    or eax, ecx
    add rsi, 2
    add rsi, rax
    movzx eax, byte [rsi]
    shl eax, 8
    movzx ecx, byte [rsi+1]
    or eax, ecx
    add rsi, 2
    cmp eax, 16
    jne .rxa_skip
    lea rdi, [xauth_data]
    mov ecx, 16
.rxa_cp_cookie:
    mov bl, [rsi]
    mov [rdi], bl
    inc rsi
    inc rdi
    dec ecx
    jnz .rxa_cp_cookie
    mov qword [xauth_len], 16
    jmp .rxa_done
.rxa_skip:
    add rsi, rax
    jmp .rxa_parse
.rxa_done:
    pop r12
    pop rbx
    ret

; ============================================================================
; x11_connect — connect, send setup with cookie, read full reply.
; ============================================================================
x11_connect:
    push rbx
    push r12
    mov rax, SYS_SOCKET
    mov rdi, AF_UNIX
    mov rsi, SOCK_STREAM
    xor edx, edx
    syscall
    test rax, rax
    js .xc_fail
    mov [x11_fd], rax
    mov rbx, rax

    lea rdi, [sockaddr_buf]
    mov word [rdi], AF_UNIX
    add rdi, 2
    lea rsi, [x11_sock_pre]
.xc_cp_path:
    mov al, [rsi]
    test al, al
    jz .xc_cp_num
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .xc_cp_path
.xc_cp_num:
    mov rax, [display_num]
    call itoa_in_place
    mov rax, SYS_CONNECT
    mov rdi, rbx
    lea rsi, [sockaddr_buf]
    mov rdx, 110
    syscall
    test rax, rax
    js .xc_fail

    lea rdi, [tmp_buf]
    mov byte [rdi], 0x6C
    mov byte [rdi+1], 0
    mov word [rdi+2], 11
    mov word [rdi+4], 0
    mov word [rdi+6], auth_name_len
    movzx eax, word [xauth_len]
    mov word [rdi+8], ax
    mov word [rdi+10], 0
    lea rsi, [auth_name]
    lea rdi, [tmp_buf + 12]
    mov ecx, auth_name_len
.xc_cp_aname:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz .xc_cp_aname
    mov ecx, auth_name_len
    and ecx, 3
    jz .xc_aname_padded
    mov edx, 4
    sub edx, ecx
.xc_pad_aname:
    mov byte [rdi], 0
    inc rdi
    dec edx
    jnz .xc_pad_aname
.xc_aname_padded:
    cmp qword [xauth_len], 0
    je .xc_no_data
    lea rsi, [xauth_data]
    mov ecx, 16
.xc_cp_adata:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz .xc_cp_adata
.xc_no_data:
    mov rdx, rdi
    lea rsi, [tmp_buf]
    sub rdx, rsi
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    syscall

    xor r12d, r12d
.xc_read_loop:
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [conn_setup_buf]
    add rsi, r12
    mov rdx, 32768
    sub rdx, r12
    jle .xc_read_done
    syscall
    test rax, rax
    jle .xc_fail
    add r12, rax
    cmp r12, 8
    jl .xc_read_loop
    movzx eax, word [conn_setup_buf + 6]
    shl eax, 2
    add eax, 8
    cmp r12d, eax
    jl .xc_read_loop
.xc_read_done:
    cmp byte [conn_setup_buf], 1
    jne .xc_fail
    xor eax, eax
    pop r12
    pop rbx
    ret
.xc_fail:
    mov rax, -1
    pop r12
    pop rbx
    ret

itoa_in_place:
    test rax, rax
    jnz .iip_pos
    mov byte [rdi], '0'
    inc rdi
    mov byte [rdi], 0
    ret
.iip_pos:
    mov rcx, 10
    mov r8, rdi
.iip_div:
    test rax, rax
    jz .iip_done_div
    xor edx, edx
    div rcx
    add dl, '0'
    mov [rdi], dl
    inc rdi
    jmp .iip_div
.iip_done_div:
    mov byte [rdi], 0
    mov rsi, rdi
    dec rsi
.iip_rev:
    cmp r8, rsi
    jge .iip_rev_done
    mov al, [r8]
    mov dl, [rsi]
    mov [r8], dl
    mov [rsi], al
    inc r8
    dec rsi
    jmp .iip_rev
.iip_rev_done:
    ret

; ============================================================================
; x11_parse_setup — root window, root visual, root depth, screen dims.
; ============================================================================
x11_parse_setup:
    lea rsi, [conn_setup_buf]
    mov eax, [rsi + 12]
    mov [x11_rid_base], eax
    mov eax, [rsi + 16]
    mov [x11_rid_mask], eax
    mov dword [x11_rid_next], 1
    mov dword [x11_seq], 1
    movzx eax, word [rsi + 24]      ; vendor length
    add eax, 3
    and eax, ~3
    add eax, 40
    movzx ecx, byte [rsi + 29]
    imul ecx, 8
    add eax, ecx
    lea rdx, [rsi + rax]            ; SCREEN0
    mov ecx, [rdx]
    mov [root_window], ecx
    mov ecx, [rdx + 32]
    mov [root_visual], ecx
    movzx ecx, byte [rdx + 38]
    mov [root_depth], cl
    mov ax, [rdx + 20]
    mov [screen_w], ax
    mov ax, [rdx + 22]
    mov [screen_h], ax
    ; min/max keycode are in the connection setup body at offsets 34/35
    ; (relative to its start, which is conn_setup_buf + 8 because we read
    ; the 8-byte success header into the same buffer).
    movzx eax, byte [rsi + 34]
    mov [min_keycode], al
    movzx eax, byte [rsi + 35]
    mov [max_keycode], al
    ret

; ============================================================================
; query_shape — QueryExtension "SHAPE" → major opcode in shape_major (0 if no).
; ============================================================================
query_shape:
    push rbx
    push r12
    push r13
    lea r12, [shape_name]
    mov r13d, shape_name_len
    mov eax, r13d
    add eax, 3
    and eax, ~3
    mov ebx, eax
    add eax, 8
    shr eax, 2
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_QUERY_EXTENSION
    mov byte [rdi+1], 0
    mov word [rdi+2], ax
    mov word [rdi+4], r13w
    mov word [rdi+6], 0
    lea rdi, [tmp_buf + 8]
    mov rsi, r12
    mov ecx, r13d
.qs_cp:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz .qs_cp
    mov ecx, r13d
    and ecx, 3
    jz .qs_padded
    mov edx, 4
    sub edx, ecx
.qs_pad:
    mov byte [rdi], 0
    inc rdi
    dec edx
    jnz .qs_pad
.qs_padded:
    mov rdx, rdi
    lea rsi, [tmp_buf]
    sub rdx, rsi
    call x11_buffer
    inc dword [x11_seq]
    call x11_flush
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [read_buf]
    mov rdx, 32
    syscall
    cmp rax, 32
    jl .qs_no
    cmp byte [read_buf], 1
    jne .qs_no
    cmp byte [read_buf + 8], 1
    jne .qs_no
    movzx eax, byte [read_buf + 9]
    mov [shape_major], al
    jmp .qs_done
.qs_no:
    mov byte [shape_major], 0
.qs_done:
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; create_overlay — InputOutput window using root visual, full root,
; override-redirect, dark-gray background.
; ============================================================================
create_overlay:
    push rbx
    call alloc_xid
    mov [overlay_win], eax
    mov ebx, eax

    lea rdi, [tmp_buf]
    mov byte [rdi], X11_CREATE_WINDOW
    mov byte [rdi+1], COPY_FROM_PARENT  ; depth = parent's
    mov word [rdi+2], 11                ; len = 8 fixed + 3 values
    mov [rdi+4], ebx
    mov edx, [root_window]
    mov [rdi+8], edx
    mov word [rdi+12], 0                ; x
    mov word [rdi+14], 0                ; y
    mov ax, [screen_w]
    mov [rdi+16], ax
    mov ax, [screen_h]
    mov [rdi+18], ax
    mov word [rdi+20], 0                ; border width
    mov word [rdi+22], INPUT_OUTPUT
    mov dword [rdi+24], COPY_FROM_PARENT ; visual
    mov dword [rdi+28], CW_BACK_PIXEL | CW_OVERRIDE_REDIRECT | CW_EVENT_MASK
    mov edx, [back_pixel]
    mov [rdi+32], edx                   ; back pixel (computed from dim_pct)
    mov dword [rdi+36], 1               ; override = true
    mov dword [rdi+40], EVMASK_KEY_PRESS | EVMASK_EXPOSURE | EVMASK_STRUCTURE
    lea rsi, [tmp_buf]
    mov rdx, 44
    call x11_buffer
    inc dword [x11_seq]

    ; MapWindow
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_MAP_WINDOW
    mov byte [rdi+1], 0
    mov word [rdi+2], 2
    mov [rdi+4], ebx
    lea rsi, [tmp_buf]
    mov rdx, 8
    call x11_buffer
    inc dword [x11_seq]
    pop rbx
    ret

; ============================================================================
; set_input_passthrough — SHAPE Rectangles op=Set, kind=Input, 0 rectangles.
; → window doesn't intercept pointer events.
; ============================================================================
set_input_passthrough:
    lea rdi, [tmp_buf]
    mov al, [shape_major]
    mov [rdi], al
    mov byte [rdi+1], SHAPE_RECTANGLES
    mov word [rdi+2], 4
    mov byte [rdi+4], SHAPE_SET
    mov byte [rdi+5], SHAPE_KIND_INPUT
    mov byte [rdi+6], SHAPE_UNSORTED
    mov byte [rdi+7], 0
    mov edx, [overlay_win]
    mov [rdi+8], edx
    mov word [rdi+12], 0
    mov word [rdi+14], 0
    lea rsi, [tmp_buf]
    mov rdx, 16
    call x11_buffer
    inc dword [x11_seq]
    ret

; ============================================================================
; parse_dim — read SPOT_DIM from envp (0..100). Defaults to DEFAULT_DIM.
; Then computes back_pixel = grayscale 0xRRGGBB with R=G=B = (100-dim)*255/100.
;   dim=100 → 0x000000 (full black)
;   dim=0   → 0xFFFFFF (white)
;   dim=80  → 0x333333 (default, similar to old hard-coded 0x202020)
; ============================================================================
parse_dim:
    mov dword [dim_pct], DEFAULT_DIM
    mov rcx, [envp]
.pd_loop:
    mov rdi, [rcx]
    test rdi, rdi
    jz .pd_done
    cmp dword [rdi], 'SPOT'
    jne .pd_next
    cmp dword [rdi+4], '_DIM'
    jne .pd_next
    cmp byte  [rdi+8], '='
    jne .pd_next
    add rdi, 9
    xor eax, eax
.pd_digit:
    movzx edx, byte [rdi]
    sub edx, '0'
    cmp edx, 9
    ja .pd_save
    imul eax, eax, 10
    add eax, edx
    cmp eax, 100
    jg .pd_done                     ; bad value → keep default
    inc rdi
    jmp .pd_digit
.pd_save:
    mov [dim_pct], eax
    jmp .pd_done
.pd_next:
    add rcx, 8
    jmp .pd_loop
.pd_done:
    ; gray = (100 - dim_pct) * 255 / 100
    mov eax, 100
    sub eax, [dim_pct]
    imul eax, 255
    mov ecx, 100
    xor edx, edx
    div ecx                         ; eax = gray (0..255)
    mov edx, eax
    shl eax, 16
    or eax, edx
    shl edx, 8
    or eax, edx                     ; 0x00RRGGBB with R=G=B=gray
    mov [back_pixel], eax
    ret

; ============================================================================
; build_circle_table — circle_hw[i] = floor(sqrt(R*R - i*i)) for i in 0..R.
; Walks x down from R, incremental compare: x*x ≤ target ≤ (x+1)*(x+1).
; ============================================================================
build_circle_table:
    push rbx
    push r12
    push r13
    mov r12d, SPOT_RADIUS           ; current x guess
    xor r13d, r13d                  ; i = 0
.bct_loop:
    cmp r13d, SPOT_RADIUS + 1
    jge .bct_done
    mov eax, SPOT_RADIUS * SPOT_RADIUS
    mov ecx, r13d
    imul ecx, r13d
    sub eax, ecx                    ; target = R² - i²
.bct_shrink:
    mov ecx, r12d
    imul ecx, r12d
    cmp ecx, eax
    jle .bct_save
    dec r12d
    jmp .bct_shrink
.bct_save:
    lea rdi, [circle_hw]
    mov [rdi + r13*2], r12w
    inc r13d
    jmp .bct_loop
.bct_done:
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; set_bounding_circle — SHAPE Rectangles op=Set, kind=Bounding, with a circular
; hole. The bounding region is a top band, a bottom band, and two slivers per
; row in [cy-R, cy+R-1]. Per-row half-width comes from circle_hw[].
; ============================================================================
set_bounding_circle:
    push rbx
    push r12
    push r13
    push r14
    push r15

    movzx r12d, word [cursor_x]
    movzx r13d, word [cursor_y]
    movzx r14d, word [screen_w]
    movzx r15d, word [screen_h]

    ; Build request header at bounds_buf + 0..15.
    lea rdi, [bounds_buf]
    mov al, [shape_major]
    mov [rdi], al
    mov byte [rdi+1], SHAPE_RECTANGLES
    ; word [rdi+2] = length, filled in at end
    mov byte [rdi+4], SHAPE_SET
    mov byte [rdi+5], SHAPE_KIND_BOUNDING
    mov byte [rdi+6], SHAPE_UNSORTED
    mov byte [rdi+7], 0
    mov edx, [overlay_win]
    mov [rdi+8], edx
    mov word [rdi+12], 0            ; x offset
    mov word [rdi+14], 0            ; y offset

    ; rbx walks the rect output cursor.
    lea rbx, [bounds_buf + 16]

    ; TOP band: (0, 0, W, cy-R) if cy > 0.
    mov eax, r13d
    sub eax, SPOT_RADIUS
    jle .sbc_skip_top
    mov word [rbx], 0
    mov word [rbx+2], 0
    mov [rbx+4], r14w
    cmp eax, r15d
    jle .sbc_top_clip
    mov eax, r15d
.sbc_top_clip:
    mov [rbx+6], ax
    add rbx, 8
.sbc_skip_top:

    ; BOTTOM band: (0, cy+R, W, H-(cy+R)) if cy+R < H.
    mov eax, r13d
    add eax, SPOT_RADIUS
    cmp eax, r15d
    jge .sbc_skip_bot
    test eax, eax
    jns .sbc_bot_ge0
    xor eax, eax
.sbc_bot_ge0:
    mov word [rbx], 0
    mov [rbx+2], ax                 ; y = cy + R
    mov [rbx+4], r14w
    mov ecx, r15d
    sub ecx, eax                    ; H - (cy+R)
    mov [rbx+6], cx
    add rbx, 8
.sbc_skip_bot:

    ; Per-row left/right slivers for y in [cy-R, cy+R-1].
    ; r8d = y; r9d = signed y offset from cy (range -R .. R-1).
    mov r8d, r13d
    sub r8d, SPOT_RADIUS
    mov r9d, -SPOT_RADIUS
.sbc_row:
    cmp r9d, SPOT_RADIUS
    jge .sbc_rows_done
    test r8d, r8d
    js .sbc_row_advance
    cmp r8d, r15d
    jge .sbc_rows_done
    mov eax, r9d
    test eax, eax
    jns .sbc_pos
    neg eax
.sbc_pos:
    lea rcx, [circle_hw]
    movzx eax, word [rcx + rax*2]   ; hw at this row
    mov ecx, eax                    ; ecx = hw
    ; LEFT sliver: (0, y, cx - hw, 1) if cx > hw.
    mov edx, r12d
    sub edx, ecx
    jle .sbc_no_left
    cmp edx, r14d
    jle .sbc_left_ok
    mov edx, r14d
.sbc_left_ok:
    mov word [rbx], 0
    mov [rbx+2], r8w
    mov [rbx+4], dx
    mov word [rbx+6], 1
    add rbx, 8
.sbc_no_left:
    ; RIGHT sliver: (cx + hw, y, W - (cx+hw), 1) if cx+hw < W.
    mov edx, r12d
    add edx, ecx
    cmp edx, r14d
    jge .sbc_no_right
    test edx, edx
    jns .sbc_right_ok
    xor edx, edx
.sbc_right_ok:
    mov [rbx], dx
    mov [rbx+2], r8w
    mov eax, r14d
    sub eax, edx
    mov [rbx+4], ax
    mov word [rbx+6], 1
    add rbx, 8
.sbc_no_right:
.sbc_row_advance:
    inc r8d
    inc r9d
    jmp .sbc_row
.sbc_rows_done:

    ; Total request length (bytes) and patch the length field.
    lea rax, [bounds_buf]
    sub rbx, rax                    ; total bytes
    mov rdx, rbx                    ; save for write
    shr rbx, 2                      ; length in 4-byte units
    mov [bounds_buf + 2], bx

    ; Flush any pending small requests, then write the bounds request direct.
    ; (x11_flush clobbers rdx — save it.)
    push rdx
    call x11_flush
    pop rdx
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    lea rsi, [bounds_buf]
    syscall
    inc dword [x11_seq]

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; query_keymap — GetKeyboardMapping for [min_keycode .. max_keycode], scan
; the keysym body for XK_Escape (0xFF1B) and XK_q (0x71), populate the
; *_keycode globals. v0.1.1 hard-coded kc=9/24 which is wrong on layouts
; that remap (e.g. Norwegian/evdev pc105: Esc lands at keycode 66).
; ============================================================================
query_keymap:
    push rbx
    push r12
    push r13
    push r14
    push r15
    movzx ebx, byte [min_keycode]
    movzx ecx, byte [max_keycode]
    sub ecx, ebx
    inc ecx                         ; count = max - min + 1
    mov r12d, ecx                   ; r12 = keycode count

    lea rdi, [tmp_buf]
    mov byte [rdi], X11_GET_KEYBOARD_MAPPING
    mov byte [rdi+1], 0
    mov word [rdi+2], 2
    mov [rdi+4], bl                 ; first_keycode
    mov [rdi+5], cl                 ; count
    mov word [rdi+6], 0
    lea rsi, [tmp_buf]
    mov rdx, 8
    call x11_buffer
    inc dword [x11_seq]
    call x11_flush

    ; Read 32-byte reply header.
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [read_buf]
    mov rdx, 32
    syscall
    cmp rax, 32
    jl .qk_done
    cmp byte [read_buf], 1          ; type 1 = Reply
    jne .qk_done
    movzx r13d, byte [read_buf + 1] ; keysyms per keycode
    test r13d, r13d
    jz .qk_done
    mov eax, [read_buf + 4]         ; body length in 4-byte units
    shl eax, 2                      ; bytes
    mov r14d, eax                   ; total body bytes

    ; Drain the body into conn_setup_buf (already large enough).
    xor r15d, r15d
.qk_drain:
    cmp r15d, r14d
    jge .qk_drained
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [conn_setup_buf]
    add rsi, r15
    mov edx, r14d
    sub edx, r15d
    syscall
    test rax, rax
    jle .qk_drained
    add r15d, eax
    jmp .qk_drain
.qk_drained:

    ; Scan: for each keycode i in [0 .. count) and slot in [0 .. keysyms_per_kc),
    ; check keysym at body + (i * keysyms_per_kc + slot) * 4.
    xor ecx, ecx                    ; i
.qk_loop_i:
    cmp ecx, r12d
    jge .qk_done
    xor edx, edx                    ; slot
.qk_loop_s:
    cmp edx, r13d
    jge .qk_next_i
    mov eax, ecx
    imul eax, r13d
    add eax, edx
    shl eax, 2                      ; byte offset
    mov eax, [conn_setup_buf + rax]
    cmp eax, XK_ESCAPE
    jne .qk_not_esc
    mov edi, ebx
    add edi, ecx
    mov [esc_keycode], dil
    jmp .qk_advance_s
.qk_not_esc:
    cmp eax, XK_Q
    jne .qk_advance_s
    mov edi, ebx
    add edi, ecx
    mov [q_keycode], dil
.qk_advance_s:
    inc edx
    jmp .qk_loop_s
.qk_next_i:
    inc ecx
    jmp .qk_loop_i
.qk_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; grab_keys — passive GrabKey on root for Esc and q with AnyModifier. These
; grabs trigger an active grab on press → events route to us regardless of
; current input focus, so Esc always works even while no window owns focus.
; Doing the grabs BEFORE creating the overlay avoids any window-viewability
; race that bit v0.1.0 (GrabKeyboard called pre-MapNotify → NotViewable).
; ============================================================================
grab_keys:
    push rbx
    mov bl, [esc_keycode]
    test bl, bl
    jz .gk_skip_esc
    call .gk_one
.gk_skip_esc:
    mov bl, [q_keycode]
    test bl, bl
    jz .gk_skip_q
    call .gk_one
.gk_skip_q:
    pop rbx
    ret
.gk_one:
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_GRAB_KEY
    mov byte [rdi+1], 1                 ; owner_events
    mov word [rdi+2], 4
    mov edx, [root_window]
    mov [rdi+4], edx
    mov word [rdi+8], ANY_MODIFIER
    mov [rdi+10], bl                    ; key
    mov byte [rdi+11], GRAB_MODE_ASYNC  ; pointer mode
    mov byte [rdi+12], GRAB_MODE_ASYNC  ; keyboard mode
    mov byte [rdi+13], 0
    mov word [rdi+14], 0
    lea rsi, [tmp_buf]
    mov rdx, 16
    call x11_buffer
    inc dword [x11_seq]
    ret

; ============================================================================
; query_pointer_once — seed cursor_x / cursor_y from the X server.
; ============================================================================
query_pointer_once:
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_QUERY_POINTER
    mov byte [rdi+1], 0
    mov word [rdi+2], 2
    mov edx, [root_window]
    mov [rdi+4], edx
    lea rsi, [tmp_buf]
    mov rdx, 8
    call x11_buffer
    inc dword [x11_seq]
    call x11_flush
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [read_buf]
    mov rdx, 32
    syscall
    cmp rax, 32
    jl .qpo_zero
    cmp byte [read_buf], 1
    jne .qpo_zero
    movzx eax, word [read_buf + 16]
    mov [cursor_x], ax
    mov [last_x], ax
    movzx eax, word [read_buf + 18]
    mov [cursor_y], ax
    mov [last_y], ax
    ret
.qpo_zero:
    mov word [cursor_x], 0
    mov word [cursor_y], 0
    mov word [last_x], 0xFFFF       ; force redraw on first tick
    mov word [last_y], 0xFFFF
    ret

; ============================================================================
; event_loop — poll(socket, 33ms). On data: drain events, Esc/q → exit.
; On timeout: query pointer; if moved, redraw the bounding hole.
; ============================================================================
event_loop:
    push rbx
.el_loop:
    sub rsp, 16
    mov eax, [x11_fd]
    mov [rsp], eax                  ; fd (4)
    mov word [rsp+4], POLLIN
    mov word [rsp+6], 0
    mov rax, SYS_POLL
    mov rdi, rsp
    mov rsi, 1
    mov rdx, 33
    syscall
    mov ebx, eax
    add rsp, 16

    test ebx, ebx
    jz .el_tick
    js .el_loop

    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [read_buf]
    mov rdx, 32
    syscall
    cmp rax, 32
    jl .el_loop
    movzx eax, byte [read_buf]
    and eax, 0x7F
    cmp eax, EV_KEY_PRESS
    je .el_keypress
    jmp .el_loop

.el_keypress:
    movzx eax, byte [read_buf + 1]
    movzx ecx, byte [esc_keycode]
    cmp eax, ecx
    je .el_exit
    movzx ecx, byte [q_keycode]
    cmp eax, ecx
    je .el_exit
    jmp .el_loop

.el_tick:
    call query_pointer_once_silent
    movzx eax, word [cursor_x]
    movzx ecx, word [last_x]
    cmp eax, ecx
    jne .el_moved
    movzx eax, word [cursor_y]
    movzx ecx, word [last_y]
    cmp eax, ecx
    je .el_loop
.el_moved:
    movzx eax, word [cursor_x]
    mov [last_x], ax
    movzx eax, word [cursor_y]
    mov [last_y], ax
    call set_bounding_circle
    call x11_flush
    jmp .el_loop

.el_exit:
    pop rbx
    ret

; query_pointer_once_silent — same as query_pointer_once but doesn't touch
; last_x/last_y. Used by the tick path so we can detect motion deltas.
query_pointer_once_silent:
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_QUERY_POINTER
    mov byte [rdi+1], 0
    mov word [rdi+2], 2
    mov edx, [root_window]
    mov [rdi+4], edx
    lea rsi, [tmp_buf]
    mov rdx, 8
    call x11_buffer
    inc dword [x11_seq]
    call x11_flush
    mov rax, SYS_READ
    mov rdi, [x11_fd]
    lea rsi, [read_buf]
    mov rdx, 32
    syscall
    cmp rax, 32
    jl .qps_done
    cmp byte [read_buf], 1
    jne .qps_done
    movzx eax, word [read_buf + 16]
    mov [cursor_x], ax
    movzx eax, word [read_buf + 18]
    mov [cursor_y], ax
.qps_done:
    ret

; ============================================================================
; cleanup — ungrab + destroy.
; ============================================================================
cleanup:
    ; UngrabKey(root, Esc/q, AnyModifier) using the dynamically-resolved
    ; keycodes from query_keymap. Skip when 0 (grab never installed).
    push rbx
    mov bl, [esc_keycode]
    test bl, bl
    jz .cu_skip_esc
    call .cu_ungrab
.cu_skip_esc:
    mov bl, [q_keycode]
    test bl, bl
    jz .cu_skip_q
    call .cu_ungrab
.cu_skip_q:
    pop rbx
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_DESTROY_WINDOW
    mov byte [rdi+1], 0
    mov word [rdi+2], 2
    mov edx, [overlay_win]
    mov [rdi+4], edx
    lea rsi, [tmp_buf]
    mov rdx, 8
    call x11_buffer
    inc dword [x11_seq]
    call x11_flush
    mov rax, SYS_CLOSE
    mov rdi, [x11_fd]
    syscall
    ret
.cu_ungrab:
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_UNGRAB_KEY
    mov [rdi+1], bl                 ; keycode in opcode-data byte
    mov word [rdi+2], 3             ; length 3 words
    mov edx, [root_window]
    mov [rdi+4], edx
    mov word [rdi+8], ANY_MODIFIER
    mov word [rdi+10], 0
    lea rsi, [tmp_buf]
    mov rdx, 12
    call x11_buffer
    inc dword [x11_seq]
    ret

; ============================================================================
; alloc_xid / x11_buffer / x11_flush
; ============================================================================
alloc_xid:
    mov eax, [x11_rid_next]
    inc dword [x11_rid_next]
    and eax, [x11_rid_mask]
    or  eax, [x11_rid_base]
    ret

x11_buffer:
    push rbx
    mov rbx, [write_pos]
    lea rdi, [write_buf + rbx]
    xor ecx, ecx
.xb_cp:
    cmp rcx, rdx
    jge .xb_done
    movzx eax, byte [rsi + rcx]
    mov [rdi + rcx], al
    inc rcx
    jmp .xb_cp
.xb_done:
    add rbx, rdx
    mov [write_pos], rbx
    cmp rbx, 60000
    jl .xb_no_flush
    call x11_flush
.xb_no_flush:
    pop rbx
    ret

x11_flush:
    mov rdx, [write_pos]
    test rdx, rdx
    jz .xf_done
    mov rax, SYS_WRITE
    mov rdi, [x11_fd]
    lea rsi, [write_buf]
    syscall
    mov qword [write_pos], 0
.xf_done:
    ret
