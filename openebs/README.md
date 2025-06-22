# Disk Quotas on local filesystem


See <https://github.com/openebs/zfs-localpv/blob/develop/docs/quickstart.md#setup>

Requires a zpool is setup on the host first!!

```
sudo apt update && sudo apt install zfsutils-linux -y
```


Set up the zpool:

```
sudo zpool create -f openebs-zpool mirror /dev/sda /dev/sdb mirror /dev/sdd /dev/sdd
```



Verify setup:

```
sudo zpool status openebs-zpool
sudo zfs list
```



Install openebs using helm:

```
helm repo add openebs https://openebs.github.io/openebs
helm repo update
helm install openebs openebs/openebs -n openebs --create-namespace
```



Add the zfs storageClass by creating a yaml file (e.g. `zfs-storage.yml`) as follows

```
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-zfs
parameters:
  recordsize: "128k"
  compression: "off"
  dedup: "off"
  fstype: "zfs"
  poolname: "openebs-zpool"
provisioner: zfs.csi.openebs.io


```

See details in <https://github.com/openebs/zfs-localpv/blob/develop/docs/quickstart.md#setup>
Note that `fstype` should be `zfs` in this case, and be sure to match the `poolname` to the one created with zpool.  The `metadata.name` should match what we will use in the pods / pvc storageClass. Apply the yaml to create the storageClass.

```
kubectl apply -f zfs-storage.yml
```


Request the storageClass on pods / pvcs, e.g. in juypter:

```
singleuser:
  storage:
    type: dynamic
    capacity: 60Gi
    homeMountPath: /home/jovyan
    dynamic:
      storageClass:  openebs-zfs
      pvcNameTemplate: claim-{escaped_user_server}
      volumeNameTemplate: volume-{escaped_user_server}
      storageAccessModes: [ReadWriteOnce]
```


