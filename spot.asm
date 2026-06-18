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
%define X11_GRAB_KEYBOARD       31
%define X11_UNGRAB_KEYBOARD     32
%define X11_QUERY_POINTER       38
%define X11_QUERY_EXTENSION     98

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
%define SPOT_RADIUS             140       ; half-side of square hole in px
%define DARK_PIXEL              0x202020  ; dark gray fill

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
alignb 4
overlay_win:         resd 1
shape_major:         resb 1
alignb 4

cursor_x:            resw 1
cursor_y:            resw 1
last_x:              resw 1
last_y:              resw 1

sockaddr_buf:        resb 128
conn_setup_buf:      resb 32768
write_buf:           resb 65536
write_pos:           resq 1
read_buf:            resb 65536
tmp_buf:             resb 256

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
    call x11_connect
    test rax, rax
    js .die_connect
    call x11_parse_setup
    call query_shape
    cmp byte [shape_major], 0
    je .die_shape

    call create_overlay
    call set_input_passthrough
    call grab_keyboard
    call x11_flush
    call query_pointer_once
    call set_bounding_hole
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
    mov dword [rdi+32], DARK_PIXEL      ; back pixel
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
; set_bounding_hole — SHAPE Rectangles op=Set, kind=Bounding. The bounding
; region is FOUR rectangles forming a frame around the cursor: top strip,
; bottom strip, left bar, right bar. The 2R×2R square at (cursor_x, cursor_y)
; is excluded → desktop shows through there.
;
; Rectangle layout (cx, cy = cursor; R = SPOT_RADIUS; W,H = screen):
;
;   ┌──────────────────────────┐
;   │           top            │   top:    (0, 0,  W,        cy-R)
;   ├──────┬───────────┬───────┤
;   │ left │   HOLE    │ right │   left:   (0, cy-R, cx-R,   2R)
;   ├──────┴───────────┴───────┤   right:  (cx+R, cy-R, W-(cx+R), 2R)
;   │          bottom          │   bottom: (0, cy+R, W,      H-(cy+R))
;   └──────────────────────────┘
;
; Cropped against screen edges so we never send a negative width.
; ============================================================================
set_bounding_hole:
    push rbx
    push r12
    push r13
    push r14
    push r15

    movzx r12d, word [cursor_x]
    movzx r13d, word [cursor_y]
    movzx r14d, word [screen_w]
    movzx r15d, word [screen_h]

    ; hole bbox: x1=cx-R, y1=cy-R, x2=cx+R, y2=cy+R, clamped to [0..screen]
    mov eax, r12d
    sub eax, SPOT_RADIUS
    jns .sb_x1_ok
    xor eax, eax
.sb_x1_ok:
    mov ebx, eax                    ; x1
    mov eax, r13d
    sub eax, SPOT_RADIUS
    jns .sb_y1_ok
    xor eax, eax
.sb_y1_ok:
    mov ecx, eax                    ; y1
    mov eax, r12d
    add eax, SPOT_RADIUS
    cmp eax, r14d
    jle .sb_x2_ok
    mov eax, r14d
.sb_x2_ok:
    mov edx, eax                    ; x2
    mov eax, r13d
    add eax, SPOT_RADIUS
    cmp eax, r15d
    jle .sb_y2_ok
    mov eax, r15d
.sb_y2_ok:
    ; rdx = x2; rcx = y1; rbx = x1; rax = y2; r14 = W; r15 = H
    ; Build 4 rectangles into tmp_buf+16 (16 = request header)
    lea rdi, [tmp_buf]
    mov r8b, [shape_major]
    mov [rdi], r8b
    mov byte [rdi+1], SHAPE_RECTANGLES
    mov word [rdi+2], 4 + 4 * 2     ; 4 header words + 4 rects × 2 words
    mov byte [rdi+4], SHAPE_SET
    mov byte [rdi+5], SHAPE_KIND_BOUNDING
    mov byte [rdi+6], SHAPE_UNSORTED
    mov byte [rdi+7], 0
    mov r8d, [overlay_win]
    mov [rdi+8], r8d
    mov word [rdi+12], 0            ; x offset
    mov word [rdi+14], 0            ; y offset

    ; rect 1: TOP — (0, 0, W, y1)
    lea rdi, [tmp_buf + 16]
    mov word [rdi], 0
    mov word [rdi+2], 0
    mov [rdi+4], r14w               ; W
    mov [rdi+6], cx                 ; y1 (height)

    ; rect 2: BOTTOM — (0, y2, W, H - y2)
    mov word [rdi+8], 0
    mov [rdi+10], ax                ; y2
    mov [rdi+12], r14w              ; W
    mov r9d, r15d
    sub r9d, eax                    ; H - y2
    mov [rdi+14], r9w

    ; rect 3: LEFT — (0, y1, x1, y2 - y1)
    mov word [rdi+16], 0
    mov [rdi+18], cx                ; y1
    mov [rdi+20], bx                ; x1 (width)
    mov r9d, eax
    sub r9d, ecx                    ; y2 - y1
    mov [rdi+22], r9w

    ; rect 4: RIGHT — (x2, y1, W - x2, y2 - y1)
    mov [rdi+24], dx                ; x2
    mov [rdi+26], cx                ; y1
    mov r9d, r14d
    sub r9d, edx                    ; W - x2
    mov [rdi+28], r9w
    mov r9d, eax
    sub r9d, ecx
    mov [rdi+30], r9w

    lea rsi, [tmp_buf]
    mov rdx, 48
    call x11_buffer
    inc dword [x11_seq]

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; grab_keyboard — GrabKeyboard so Esc reaches us regardless of pointer focus.
; ============================================================================
grab_keyboard:
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_GRAB_KEYBOARD
    mov byte [rdi+1], 1
    mov word [rdi+2], 4
    mov edx, [overlay_win]
    mov [rdi+4], edx
    mov dword [rdi+8], 0
    mov byte [rdi+12], GRAB_MODE_ASYNC
    mov byte [rdi+13], GRAB_MODE_ASYNC
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
    cmp eax, 9                      ; Esc (standard kc on Linux X11)
    je .el_exit
    cmp eax, 24                     ; q
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
    call set_bounding_hole
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
    lea rdi, [tmp_buf]
    mov byte [rdi], X11_UNGRAB_KEYBOARD
    mov byte [rdi+1], 0
    mov word [rdi+2], 2
    mov dword [rdi+4], 0
    lea rsi, [tmp_buf]
    mov rdx, 8
    call x11_buffer
    inc dword [x11_seq]
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
