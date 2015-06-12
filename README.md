# Using containers to mount Kubernetes volumes

On limited docker hosts, such as CoreOS or Atomic, one cannot easily install utilities that are necessary to mount various filesystems such as Gluster. This repository contains a proof of concept how to make it possible.

## Motivation
We cannot install e.g. GlusterFS tools on the host, where Kubernetes runs. The only other option is to have a container with these tools. And we must make sure that the Gluster volume we mount *inside* the container is visible also to the *host*. Huamin Chen created [a little container](https://github.com/rootfs/install-glusterfs-on-fc21) that makes it possible using very dirty tricks. This repository uses his work and just adds some tunables to the container.

So, we have a container, that can mount GlusterFS and the host can see it. Now we must make Kubernetes to use this container. Traditionally, Kubernetes just calls `mount -t glusterfs <what> <where>`. We need it to use `docker exec <mount container> mount -t glusterfs <what> <where>`, and only for GlusterFS, all other filesystems should use plain `mount` (we do have `mount.nfs` on Atomic).

## Code
* mounter container is in [container](container/) directory.
* Kubernetes changes are in my [Kubernetes branch](https://github.com/jsafrane/kubernetes/tree/devel/container-mounter).

## Detailed instructions

### The mount container
The mount container has installed `mount.glusterfs` and "magic" `mymount.so` registered in `/etc/ld.so.preload`. It works in this way:

1. Kubernetes starts the mounter container (see below) as privileged. We need these privileges in step 4. to do `nsenter()` and eventually `mount()`.
2. Whenever Kubernetes need to mount GlusterFS, it calls `docker exec <mounter container ID> mount -t glusterfs <what> <where>`
3. Inside the container, `/bin/mount` finds `mount.glusterfs` and prepares everything for the mount as usual.
4. When `/bin/mount` calls `mount()` syscall, `mymount.so`, registered in `/etc/ld.so.preload`, catches it and enters the host mount namespace. Then it calls `mount()` syscall from there. As result, GlusterFS is mounted to the host mount namespace.
5. `mount.glusterfs` starts a fuse daemon, processing GlusterFS stuff. This daemon runs inside the mounter container.
6. Whenever Kubernetes decide to tear down the volume, it just unmounts appropriate directory *in the host namespace* (standard `/bin/umount <what>` call). The fuse daemon inside the mounter container dies automatically.

This is of course very hackish solution, it would be better to patch docker not to create a new mount namespace for this mounter container and throw away our `ld.so.preload` trick.

### Kubernetes
The daemon, resposible for mounting volumes is `kubelet`. It runs on every node, mounts volumes and starts pods and is fully controlled by Kubernetes API server.

We need `kubelet` to start a mounter container instance on every node. There are many ways how to do it, we use static containers in this proof of concept. On **every** node in Kubernetes cluster we need:

0. Compile Kubernetes from [my branch](https://github.com/jsafrane/kubernetes/tree/devel/container-mounter).

1. Create e.g. `/etc/kubelet.d` directory for static pods. The directory name does not matter, as long as the same name is used in subsequent steps.

    ```
    $ mkdir /etc/kubelet.d
    ```

2. Create a static pod with our mounter container there. The mounter container needs access to host's `/var/lib/kubelet` (that's where we will mount stuff) and `/proc` (to find `/proc/1/ns`, necessary for `nseneter()` call).

    ```
    cat <<EOF >/etc/kubelet.d/mounter.yaml
    kind: Pod
    apiVersion: v1beta3
    metadata:
      name: mounter
      labels:
        name: glusterfs-mounter
    spec:
      containers:
        - name: mounter
          image: jsafrane/glusterfs-mounter
          env:
            - name: "HOSTPROCPATH"
              value: "/host"
          privileged: true
          volumeMounts:
            - name: var
              mountPath: /var/lib/kubelet/
            - name: proc
              mountPath: /host/proc
      volumes: 
        - name: var
          hostPath:
            path: /var/lib/kubelet
        - name: proc
          hostPath:
            path: /proc
    EOF
    ```

2. Configure `kubelet` daemon. On Atomic host, edit `/etc/kubernetes/kubelet` and add `--config=...` option to set directory with static pods and `--volume-mounter=container --mount-container=...` to instruct `kubelet` to use `mounter` container to mount GlusterFS (and plain `/bin/mount` for everything else). Of course, use your local IP address instead of `192.168.100.81`.

    ```
    $ vi /etc/kubernetes/kubelet
    ...
    KUBELET_ARGS="--config=/etc/kubelet.d --volume-mounter=container --mount-container=glusterfs:default:mounter-192.168.100.81:mounter --cluster_dns=10.254.0.10 --cluster_domain=kube.local"
    ```
    
3. Restart `kubelet` and wait until it downloads the mounter container image. It should start it in a minute or so, it will be visible in `docker ps` output on the node or as *mirror pod* in `kubectl get pods` output.

    ```
    $ service kubelet restart
    $ docker ps
    CONTAINER ID        IMAGE                                  COMMAND
    d3a0318e9f56        jsafrane/glusterfs-mounter:latest      "/bin/sh -c /sleep.s" ...
    ```

4. Everything is set up now, you can start creating pods with GlusterFS volumes and Kubernetes should use the container to mount them.


## Further steps

This code is just a proof of concept. Some steps may be necessary to make it production ready:
- Don't use `ld.so.preload` trick to mount volumes from inside the container to the host mount namespace. Perhaps a new `docker run` option? Still, the container needs to be privileged to allow mounting...
- Don't use mounter pod/container names in `--volume-mounter` option. Use labels? Does `kubelet` have code to filter its pods by labels?

