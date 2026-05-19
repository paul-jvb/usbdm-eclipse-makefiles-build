/*
 * GdbBreakpointsCFV1.cpp
 *
 *  Created on: 28 Mar 2015
 *      Author: podonoghue
 */

#include "GdbBreakpoints_CFV1.h"

#include "USBDM_API.h"
#include "ArmDefinitions.h"

#include "UsbdmSystem.h"
#include "GdbBreakpoints.h"

GdbBreakpoints_CFV1::GdbBreakpoints_CFV1(BdmInterfacePtr bdmInterface) : GdbBreakpoints(bdmInterface) {
}

GdbBreakpoints_CFV1::~GdbBreakpoints_CFV1() {
}

static const uint8_t haltOpcode[] = {0x4A, 0xC8};

#define TDR_TRC_HALT (1<<30)
#define TDR_L1T      (1<<14)
#define TDR_L1EBL    (1<<13)
#define TDR_L1EPC    (1<<1)
#define TDR_L1EA_INC (1<<3)
// Level-1 R/W controls in TDR (MCF51JM128 RM §28.4)
//   L1RWI (bit 5): 0 = match per L1RW; 1 = ignore R/W (any access)
//   L1RW  (bit 4): 0 = read, 1 = write (only used when L1RWI=0)
#define TDR_L1RWI    (1<<5)
#define TDR_L1RW     (1<<4)
// CSR BSTAT field (bits 31:28): trigger status reported on halt
#define CSR_BSTAT_MASK   (0xFu<<28)
#define CSR_BSTAT_SHIFT  (28)
// BSTAT >= 0x4 indicates a Level-1 trigger fired (0x4..0x7 per RM §28.5)
#define CSR_BSTAT_L1_MIN (0x4u)
#define TDR_DISABLE  (0)

//! Activate breakpoints. \n
//! This may involve changing target code for RAM breakpoints or
//! modifying target breakpoint hardware
//!
void GdbBreakpoints_CFV1::activateBreakpoints(void) {
   LOGGING_E;
   MemoryBreakInfo *bpPtr;
   if (breakpointsActive) {
      log.print("Breakpoints already active\n");
      return;
   }
   // Memory breakpoints
   for (bpPtr = memoryBreakpoints;
        bpPtr < memoryBreakpoints+MAX_MEMORY_BREAKPOINTS;
        bpPtr++) {
      if (bpPtr->inUse) {
         log.print("(%s@%08X)\n", getBreakpointName(BreakType_softwareBreak), bpPtr->address);
         bdmInterface->readMemory(sizeof(haltOpcode),sizeof(haltOpcode),bpPtr->address,bpPtr->opcode);
         bdmInterface->writeMemory(sizeof(haltOpcode),sizeof(haltOpcode),bpPtr->address,haltOpcode);
         breakpointsActive = true;
      }
   }
   // Hardware breakpoints
   uint32_t tdrValue = TDR_DISABLE;
   if (hardwareBreakpoints[0].inUse) {
      tdrValue |= TDR_TRC_HALT|TDR_L1T|TDR_L1EBL|TDR_L1EPC;
      bdmInterface->writeDReg(CFVx_DRegPBR0, hardwareBreakpoints[0].address&~0x1);
      bdmInterface->writeDReg(CFVx_DRegPBMR, 0x00000000);
      breakpointsActive = true;
      log.print("(%s@%08X)\n", getBreakpointName(BreakType_hardwareBreak),
                                              hardwareBreakpoints[0].address&~0x1);
   }
   if (hardwareBreakpoints[1].inUse) {
      tdrValue |= TDR_TRC_HALT|TDR_L1T|TDR_L1EBL|TDR_L1EPC;
      bdmInterface->writeDReg(CFVx_DRegPBR1, hardwareBreakpoints[1].address|0x1);
      breakpointsActive = true;
      log.print("(%s@%08X)\n", getBreakpointName(BreakType_hardwareBreak),
                                              hardwareBreakpoints[1].address&~0x1);
   }
   else {
      bdmInterface->writeDReg(CFVx_DRegPBR1,0);
   }
   // Hardware watches
   if (hardwareBreakpoints[2].inUse) {
      tdrValue |= TDR_TRC_HALT|TDR_L1T|TDR_L1EBL|TDR_L1EPC;
      bdmInterface->writeDReg(CFVx_DRegPBR2, hardwareBreakpoints[2].address|0x1);
      breakpointsActive = true;
      log.print("(%s@%08X)\n", getBreakpointName(BreakType_hardwareBreak),
                                              hardwareBreakpoints[2].address&~0x1);
   }
   else {
      bdmInterface->writeDReg(CFVx_DRegPBR2,0);
   }
   if (hardwareBreakpoints[3].inUse) {
      tdrValue |= TDR_TRC_HALT|TDR_L1T|TDR_L1EBL|TDR_L1EPC;
      bdmInterface->writeDReg(CFVx_DRegPBR3, hardwareBreakpoints[3].address|0x1);
      breakpointsActive = true;
      log.print("(%s@%08X)\n", getBreakpointName(BreakType_hardwareBreak),
                                              hardwareBreakpoints[3].address&~0x1);
   }
   else {
      bdmInterface->writeDReg(CFV1_DRegPBR3,0);
   }
   if (dataWatchPoints[0].inUse) {
      // Always enable Level-1 trigger + halt + inclusive address range
      tdrValue |= TDR_TRC_HALT|TDR_L1T|TDR_L1EBL|TDR_L1EA_INC;
      // Encode R/W match per watch type (MCF51JM128 RM §28.4, L1RW/L1RWI)
      switch (dataWatchPoints[0].type) {
         case BreakType_writeWatch:
            // Match writes only: L1RWI=0, L1RW=1
            tdrValue |= TDR_L1RW;
            break;
         case BreakType_readWatch:
            // Match reads only: L1RWI=0, L1RW=0  (nothing to set)
            break;
         case BreakType_accessWatch:
         default:
            // Match any access (read or write): L1RWI=1
            tdrValue |= TDR_L1RWI;
            break;
      }
      log.print("(%s@%08X size=%u)\n",
                getBreakpointName(dataWatchPoints[0].type),
                dataWatchPoints[0].address,
                dataWatchPoints[0].size);
      bdmInterface->writeDReg(CFVx_DRegABLR, dataWatchPoints[0].address);
      bdmInterface->writeDReg(CFVx_DRegABHR, dataWatchPoints[0].address+dataWatchPoints[0].size-1);
      breakpointsActive = true;
   }
   bdmInterface->writeDReg(CFVx_DRegTDR, tdrValue);
}

//! De-activate breakpoints. \n
//! This may involve changing target code for RAM breakpoints or
//! modifying target breakpoint hardware.
//!
void GdbBreakpoints_CFV1::deactivateBreakpoints(void) {
   LOGGING_E;
   MemoryBreakInfo *bpPtr;
   if (!breakpointsActive) {
      // No active breakpoints in target
      return;
   }
   // Memory breakpoints
   for (bpPtr = memoryBreakpoints;
        bpPtr < memoryBreakpoints+MAX_MEMORY_BREAKPOINTS;
        bpPtr++) {
      if (bpPtr->inUse) {
         log.print("MEM@%08X\n", bpPtr->address);
         bdmInterface->writeMemory(sizeof(haltOpcode),sizeof(haltOpcode),bpPtr->address,bpPtr->opcode);
      }
   }
   // Hardware breakpoints
   bdmInterface->writeDReg(CFV1_DRegTDR, TDR_DISABLE);
   breakpointsActive = false;
}
//! RAM based breakpoints leave the PC pointing at the instruction following
//  the HALT instruction.  This routine checks for this situation and adjusts
//! the target PC.
//!
void GdbBreakpoints_CFV1::checkAndAdjustBreakpointHalt(void) {
   LOGGING_Q;
   // Processor halted
   unsigned long pcAddress = 0;
   bdmInterface->readPC(&pcAddress);
   pcAddress -= 2;
   if (breakpointsActive && (findMemoryBreakpoint(pcAddress) != NULL)) {
      log.print("- adjusting PC=%08lX\n", pcAddress);
      bdmInterface->writePC(pcAddress);
   }
}

// Initialise Breakpoint before first use
//
USBDM_ErrorCode GdbBreakpoints_CFV1::initBreakpoints() {
   LOGGING_Q;

   maxNumHardwareBreakPoints = MAX_HARDWARE_BREAKPOINTS;
   maxNumDataWatches         = MAX_DATA_WATCHES;
   log.print("- Number of Hardware breakpoints = %d\n", maxNumHardwareBreakPoints);
   return BDM_RC_OK;
};

/**
 * Find a hardware watchpoint that has been matched
 *
 * @param[out] address    Updated with watchpoint address if found
 * @param[out] breakType  Updated with type of watchpoint found
 *
 * @return true  => Watchpoint has been matched since last checked.
 * @return false => Watchpoint has not been matched since last checked.
 */
bool GdbBreakpoints_CFV1::findMatchedDataWatchPoint(uint32_t &address, BreakType &breakType) {
   LOGGING_Q;
   // CFV1 has a single ABLR/ABHR address-range trigger (Level-1).
   // Only entry 0 of dataWatchPoints is ever programmed by activateBreakpoints().
   if (!dataWatchPoints[0].inUse) {
      return false;
   }

   // Read CSR; BSTAT[31:28] reports trigger status while halted (RM §28.4).
   unsigned long csrValue = 0;
   USBDM_ErrorCode rc = bdmInterface->readDReg(CFV1_DRegCSR, &csrValue);
   if (rc != BDM_RC_OK) {
      log.error("readDReg(CSR) failed rc=%d\n", rc);
      return false;
   }
   uint32_t bstat = (uint32_t)((csrValue & CSR_BSTAT_MASK) >> CSR_BSTAT_SHIFT);
   log.print("CSR=0x%08lX BSTAT=0x%X\n", csrValue, bstat);

   // BSTAT < 4 means no Level-1 hardware trigger fired (likely a SW/HW PC bp).
   if (bstat < CSR_BSTAT_L1_MIN) {
      return false;
   }

   // Read back TDR to confirm Level-1 was configured for an address watch
   // (vs PC-only hardware breakpoint at the same time).
   unsigned long tdrValue = 0;
   if (bdmInterface->readDReg(CFV1_DRegTDR, &tdrValue) != BDM_RC_OK) {
      return false;
   }
   if ((tdrValue & TDR_L1EA_INC) == 0) {
      // Level-1 fired but not via the address-range trigger.
      return false;
   }

   // Report the stored watchpoint's address and type to the GDB stop reply.
   address   = dataWatchPoints[0].address;
   breakType = dataWatchPoints[0].type;
   log.print("Matched watch %s @ 0x%08X\n",
             getBreakpointName(breakType), address);
   return true;
}

int  GdbBreakpoints_CFV1::getNumberOfHardwareBreakpoints() {
   return maxNumHardwareBreakPoints;
}

int  GdbBreakpoints_CFV1::getNumberOfHardwareWatches() {
   // CFV1 BDM supports one ABLR/ABHR address-range trigger (RM §28.5).
   return 1;
}
