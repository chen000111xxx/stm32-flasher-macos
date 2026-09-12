.syntax unified
.cpu cortex-m3
.thumb

.global Reset_Handler
.global Default_Handler
.extern main

.section .isr_vector, "a", %progbits
.word _estack
.word Reset_Handler
.word Default_Handler
.word Default_Handler
.word Default_Handler
.word Default_Handler
.word Default_Handler
.word 0
.word 0
.word 0
.word 0
.word Default_Handler
.word Default_Handler
.word 0
.word Default_Handler
.word Default_Handler

/* STM32F103 medium-density devices have 68 external interrupt vectors. */
.rept 68
.word Default_Handler
.endr

.section .text.Reset_Handler, "ax", %progbits
.thumb_func
Reset_Handler:
    /* Copy initialized data from Flash to RAM. */
    ldr r0, =_sidata
    ldr r1, =_sdata
    ldr r2, =_edata
1:
    cmp r1, r2
    bcs 2f
    ldr r3, [r0], #4
    str r3, [r1], #4
    b 1b

    /* Clear the BSS. */
2:
    ldr r1, =_sbss
    ldr r2, =_ebss
    movs r3, #0
3:
    cmp r1, r2
    bcs 4f
    str r3, [r1], #4
    b 3b

4:
    bl main
5:
    b 5b

.section .text.Default_Handler, "ax", %progbits
.thumb_func
Default_Handler:
6:
    b 6b
