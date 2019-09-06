# Delete-ClusteredVM
Quick and simple PowerShell script that will "uncluster" a Hyper-V VM, delete its resources in Failover Clustering, trash its VHDX files, and finally delete the VM from Hyper-V.

# TODO:
- Delete the VM's folder (all the way up!). Currently leaves behind an empty folder.
- Pass the VM name in as a parameter, not an editable variable at top of script.