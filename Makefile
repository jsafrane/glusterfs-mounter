CC=gcc

lib: mymount.c
	${CC} -Wall -fPIC -shared -o mymount.so mymount.c -ldl -D_FILE_OFFSET_BITS=64 -Wall -Wextra

container: lib
	docker build -t jsafrane/glusterfs-mounter .

all: container
