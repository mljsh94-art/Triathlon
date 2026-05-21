.section .text.init
.globl _start
_start:
    # Setup stack
    li sp, 0x80500000

    # Print "SBI Echo Test Ready\r\n" using DBCN extension
    la a0, hello_msg
1:
    lbu a1, 0(a0)
    beqz a1, 2f
    
    # Save a0 (string pointer)
    mv a2, a0
    
    # DBCN write_byte: EID = 0x4442434E ('DBCN'), FID = 2, a0 = byte
    li a7, 0x4442434E
    li a6, 2
    mv a0, a1
    ecall
    
    # Restore a0
    mv a0, a2
    addi a0, a0, 1
    j 1b
2:
echo_loop:
    # We can also test DBCN read here, but for now just loop or use DBCN read?
    # DBCN read: EID = 0x4442434E, FID = 1, read requires memory buffer...
    # Actually, legacy getchar (a7=2) is much simpler for echoing. Let's just loop for now.
    j echo_loop

.section .rodata
hello_msg:
    .asciz "SBI DBCN Output Works!\r\n"
