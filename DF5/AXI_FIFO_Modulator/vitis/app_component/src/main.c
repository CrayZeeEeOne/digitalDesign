#include "xparameters.h"
#include "xil_io.h"

#define LED1 XPAR_TOP_GPIO_0_BASEADDR
#define LED2 XPAR_TOP_GPIO_1_BASEADDR

void delay()
{
    for (volatile int i = 0; i < 25000000; i++);
}

int main()
{
    while (1)
    {
        Xil_Out32(LED1, 1);
        Xil_Out32(LED2, 0);
        delay();

        Xil_Out32(LED1, 0);
        Xil_Out32(LED2, 1);
        delay();
    }

    return 0;
}