// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Xaloqi
/*
 * xs-seed-port: run in Dom0 BEFORE xenstored starts with --priv-domid N.
 *
 * Copies dom0less domain N's xenstore event channel (HVM_PARAM_STORE_EVTCHN)
 * into the evtchn_port field of N's xenstore page. That is where xenstored's
 * startup enumeration (init_domains) looks for the port of a domain it did not
 * create. Xen 4.22 on Arm allocates the page and the channel for a dom0less
 * domain with xen,enhanced but leaves that field 0. Upstream instead expects
 * init-dom0less to XS_INTRODUCE the domain, and that needs xenstore privilege:
 * with --priv-domid N the only privileged client is N itself, which cannot
 * connect until it has been introduced. SoDeV's Zephyr Dom0 avoids the problem
 * because its xenstore server (zephyr-xenlib, patches 0006/0007) enumerates
 * dom0less domains itself; this helper is the equivalent for upstream C
 * xenstored. Dom0 is the control domain here, so it may map N's page.
 */
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <xenctrl.h>
#include <xenforeignmemory.h>
#include <xen/hvm/params.h>
#include <xen/io/xs_wire.h>

int main(int argc, char **argv)
{
    uint32_t domid = argc > 1 ? (uint32_t)atoi(argv[1]) : 1;
    xc_interface *xch = xc_interface_open(NULL, NULL, 0);
    xenforeignmemory_handle *fmem = xenforeignmemory_open(NULL, 0);
    uint64_t pfn = 0, port = 0;
    if (!xch || !fmem) { perror("open"); return 1; }
    if (xc_hvm_param_get(xch, domid, HVM_PARAM_STORE_PFN, &pfn) ||
        xc_hvm_param_get(xch, domid, HVM_PARAM_STORE_EVTCHN, &port)) { perror("hvm_param_get"); return 1; }
    xen_pfn_t gfn = pfn; int err = 0;
    struct xenstore_domain_interface *intf =
        xenforeignmemory_map(fmem, domid, PROT_READ | PROT_WRITE, 1, &gfn, &err);
    if (!intf || err) { fprintf(stderr, "map pfn 0x%llx failed (%d)\n", (unsigned long long)pfn, err); return 1; }
    printf("xs-seed-port: d%u store pfn 0x%llx evtchn %llu (page had %u, connection %u)\n", domid,
           (unsigned long long)pfn, (unsigned long long)port, intf->evtchn_port, intf->connection);
    intf->evtchn_port = (uint32_t)port;
    xenforeignmemory_unmap(fmem, intf, 1);
    return 0;
}
