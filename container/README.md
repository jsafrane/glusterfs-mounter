Based on https://github.com/rootfs/install-glusterfs-on-fc21.

## Background
A Docker host (such as CoreOS and RedHat Atomic Host) usually is a minimal OS without Gluster client package. If you want to mount a Gluster filesystem, it is quite hard to do it on the host.


## Solution
I just worked out a solution to create a [Super Privileged Container](http://developerblog.redhat.com/2014/11/06/introducing-a-super-privileged-container-concept/) and run mount in the SPC's namespace but create the mount in host's namespace.

The idea is to inject my own mount before [mount(2)](http://linux.die.net/man/2/mount) is called, so we can reset the namespace, thank Colin for the mount [patch idea](https://lists.projectatomic.io/projectatomic-archives/atomic-devel/2015-February/msg00064.html).

But since I don't want to patch any existing util, I followed [Sage Weil's suggestion](http://pad.ceph.com/p/I-containers) and used [ld.preload](http://man7.org/linux/man-pages/man8/ld.so.8.html) instead. This idea can thus be applied to gluster, nfs, cephfs, and so on, once we update the switch [here](https://github.com/rootfs/install-glusterfs-on-fc21/blob/master/mymount.c#L46)

The code is at my [repo](https://github.com/rootfs/install-glusterfs-on-fc21).
Docker image is [jsafrane/glusterfs-mounter](https://registry.hub.docker.com/u/jsafrane/glusterfs-mounter/)


## How it works

First pull my Docker image


    # docker pull jsafrane/glusterfs-mounter


Then run the image in [Super Privileged Container](http://developerblog.redhat.com/2014/11/06/introducing-a-super-privileged-container-concept/) mode

    #  docker run  --privileged -d  --net=host -v /dev:/dev -v /mnt:/mnt -v /proc:/host/proc -v /run:/run -e HOSTPROCPATH=/host jsafrane/glusterfs-mounter

Use the container to run the mount, note  the  */mnt/test* is in *host's* name space

    # docker exec mount -t glusterfs <your_gluster_brick>:<your_gluster_volueme>  /mnt/test

Finally, you can check on your Docker host  to see this gluster fs mount at */mnt/test*.
