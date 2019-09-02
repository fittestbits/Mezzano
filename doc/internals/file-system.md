<!--- -*- eval: (auto-fill-mode 1); eval: (flyspell-mode 1); -*- --->

**This is intended to describe the existing Mezzano file system.**

# File Systems on Mezzano

Each type of file system on Mezzano requires a host class and two
stream classes.

One stream class must be a character stream; the other stream class
must be a binary stream. These streams must support the appropriate
stream methods.

One approach of creating these streams is to subclass the gray
streams:
  * gray:fundamental-character-input-stream and gray:fundamental-character-output-stream
  * gray:fundamental-binary-input-stream and gray:fundamental-binary-output-stream.

The host class must implement the following methods which are exported
by the mezzano.file-system package.

    parse-namestring-using-host (host namestring junk-allowed) => pathname

    namestring-using-host (host path) => namestring

    open-using-host (host path &key direction element-type if-exists if-does-not-exist external-format) => stream

    probe-using-host (host path) => pathname or NIL

    directory-using-host (host path &key) => list of pathnames

    ensure-directories-exist-using-host (host path &key verbose) => T or NIL

    rename-file-using-host (host source dest) => <ignored>

    file-write-date-using-host (host path) => Time at which file was last written

    file-author-using-host (host path) => Name of file owner

    delete-file-using-host (host path &key) => <ignored>

    expunge-directory-using-host (host path &key) => <ignored>

    truename-using-host (host path) => pathname

The function (setfable)

    mezzano.file-system:find-host (host-name &optional (errorp t)) => host

maps a host name to a host object. For each file system there must be
a such a mapping. This mapping is used for converting name strings
to/from pathname objects.  This allows the syntax of the name string
to be host dependent. For example, the "REMOTE" host uses Unix style
name strings: "REMOTE:/home/tom/abc.lisp" while the "LOCAL" host uses
LispM style name strings: "LOCAL:>home>tom>abc.lisp".

For a file system that resides on a disk partition, the host object
must have a disk object so that read and write requests can be mapped
to the appropriate disk location.

When Mezzano boots, it enumerates all of the available disks and disk
partitions. A list of these objects can be obtained by calling:

    mezzano.supervisor:all-disks () => List of disks and partitions

To create a new file system on a running system, create a host object
of the appropriate type with the desired host name and the desired
disk object. For example, the type could be fat32, the host name could
be "HOME", and the disk object selected from the results of
(mezzano.supervisor:all-disk). For this example, the host name/host
object mapping would be setup by

    (setf (mezzano.file-system:find-host  "HOME") <fat32 host object>)

If the system is rebooted without saving the current state using:

    mezzano.supervisor:snapshot () => <ignored>

then the host object will be lost and will need to be recreated and
mapped to the appropriate host name and associated with the
appropriate disk object.

However, if the system is saved, when the system is rebooted, the host
object and host name mapping will still exist, however, the disk
object will no longer be valid.

___
**Proposal: #3 (modified version of proposal #2 below updated 3/31/19)**

Create a class "file-host-mount-mixin" which includes a "mount-args"
slot which is accessed via an accessor function file-host-mount-args
and defines a generic function:

    mount (host) => T or signals a host type dependent error

and includes a default mount method which does nothing and returns T
(success).

All file system host classes include file-host-mount-mixin and when a
file system host is created, the mount-args slot is set to a value
that depends on both the host type and the file system associated with
the host. For example, for a FAT32 host, the mount-args slot would be
set to partition UUID, and for a nfs host, the mount-args slot might
be set to the url of the nfs file system, e.g.,
"nfs://nfs.lispm.net/export/home/tom".

During the boot process, after the disks and partitions are
enumerated, but before any file system references occur, mount is
called for each of the host objects registered with
mezzano.file-system:find-host. This method should:

  * delete the association of the host with the (old) read/write object;
  * call the appropriate function for "finding" that file system type
with the host type and the mount-args;
  * associate the host with the new read/write object returned; and,
  * set the host field in the read/write object to the host (this
field does not currently exist in the disk object).

Local disk partitions are supported by using the function:

    find-local-partition (<class name> <partition UUID>) => <disk object>

find-local-partition will call the generic function

    probe-disk (<class name> <disk or partition object>) =>  <partition UUID> or NIL

on each disk and disk partition object until a matching partition UUID
is found and find-local-partition will return that disk or partition
object. probe-disk will return NIL if the disk or partition object is
not formatted as the given host type. If no matching partition is
found, find-local-partition will return NIL.

probe-disk is a generic function that specializes on the class name
argument. Therefore, each file system host class that supports local
partitions, will also need to define a probe-disk method. This method
needs to read the header of the disk or partition object, make enough
checks to verify that the object contains a file system of the
appropriate type, then return the partition UUID (or equivalent).

For the currently existing http host, remote host, local host and sys
host, the mount method will be a nop. So, the only change required
would be to add the file-host-mount-mixin to the existing classes:
http-host, remote-file-host, local-file-host, and logical-host. The
currently existing FAT and EXT host classes would have to be changed
to:
  * include the file-host-mount-mixin,
  * add the mount method, and,
  * add the appropriate probe-disk method.

This approach can be expanded to handle other kinds of file systems by
creating additional partition functions. For example, for nfs the
following function might be defined:

    find-nfs-partition (<nfs url>) => <nfs read/write object>

Adding the host field to the read/write object makes it easier for an
application, e.g., the namespace editor, to list read/write objects and
their associated host objects. In addition, the change to probe-disk
to return the partition UUID instead of doing the match allows
probe-disk to be used to determine the file system type of a disk or
partition object without knowing the partition UUID. For example, when
a disk or partition is formatted but not yet associated with a host
object.

___
**Proposal #1: - not selected**

\*file-system-table* is a list of entries, each entry is a list like
the following:

(\<disk id> \<partition number> \<host name> \<host class name> \<file
system dependent arguments>)

Partition numbers start at 1 to match fdisk and other disk
partitioning tools. However, this numbering does not match kboot which
starts partition numbering at 0.

The first three items: disk id, partition number, and host name are
required; the last two: host class name and file system dependent
arguments are optional.

Example entries are:

    '(#x0ef852f9 1 "HOME" fat32)
    '(#x0ef852f9 3 "fonts" tag-fs :read-only)
    '(#x0ef852f9 4 "ETC")

During the boot process, before any file system references occur and
before any mount operations (described below) occur,

    disconnect (host) => NIL

is called for each of the host objects registered with
mezzano.file-system:find-host. This method should delete the
association of the host with the (old) disk partition object. For the
currently existing remote host and local host, the disconnect
method will be a nop.

Also, during the boot process, after the disks and partitions are
enumerated, but before any file system references occur, the entries
of \*file-system-table* are matched against disk partitions from
(mezzano.supervisor:all-disks). When a match is found, find-host is
used to see if a corresponding host object already exists. If the host
object is found, the disk partition is associated with the host object
by calling the following method:

    mount (host <disk partition> <file system dependent arguments>) => T or NIL

If a host object is not found, then a host object is instantiated
using the host class name; the host object is mapped to the given host
name; and the host object is associated with the disk partition. **TBD
How is this done?  Is it just a call to make-instance and mount?**

If the host class name is not provided in the \*file-system-table*
entry and there is not already a host object associated with the host
name, the disk partition type id is used to determine what type of
file system host to create. **TBD How are disk partition type ids
mapped to host classes?**

For the remote host and the local host, the mount method will not be
called as there is no corresponding entry in \*file-system-table*.

The disconnect method is required because mount may not be called for
all of the registered hosts depending on the contents of
\*file-system-table* and which disk partitions are enumerated. Without
the disconnect method, hosts whose mount method is not called will try
to use an invalid (old) disk partition object.

___
**Proposal #2: - not selected**

Create a class "file-host-mount-mixin" which includes a "mount-form" slot and
defines a generic function:

    mount (host) => T or NIL

and includes a default mount method which does nothing and returns T
(success).

All file system host classes include file-host-mount-mixin and when a
file system host is created, the mount-form is initialized to a form
which, when evaluated, returns an object that can be used for reading
and writing data. It is expected that this form and the type of its
result will be file system specific. For example, in the case of a
file system that is mapped to a disk partition, the form will return
the disk partition object.

During the boot process, after the disks and partitions are
enumerated, but before any file system references occur, mount is
called for each of the host objects registered with
mezzano.file-system:find-host. This method should delete the
association of the host with the (old) read/write object; evaluate the
form in the mount-form slot; and, associate the host with the new
read/write object returned from that evaluation.

For the currently existing remote host and local host, the mount
method will be a nop. So, the only change required would be to add the
file-host-mount-mixin to the existing classes: remote-file-host and
local-file-host. The currently existing FAT and EXT host classes would
have to be changed to include the file-host-mount-mixin and support
the mount method.

This approach could support local disk partitions by using

     '(find-partition :disk <disk id> :partition <partition number>)

as the value of mount-slot. For example:

    '(find-partition :disk #x0ef852f9 :partition 1)

and can be expanded to handle other kinds of disk partitions like:

    '(scsi-partition :controller 0 :id 3 :partition 0)

or nfs:

    '(nfs-partition "nfs://nfs.lispm.net/export/home/tom")

At this point, only support for local partitions using:

    find-partition (&key :disk :partition) => <disk partition>

is proposed to be implemented. Other types can be added in the future
without changes to the existing code.

___
**Open Issues**

How are removable media handled?

How are file system host classes created and modified? Perhaps by
creating a "Name Space Editor" that can be used to edit existing file
system host parameters and to instantiate new file system hosts with a
set of parameters including the mount-slot form. This editor could be
expanded later to include other system configuration name spaces,
e.g., network information.

Use cases:

1. Create new file system on a partition:

    1. Select a partition
    2. Select a file system type
    3. Select a host name
    4. Create host
    5. Format the partition -> provides UUID
    6. Associate UUID with host

2. Create host for existing file system on a partition:

    1. Select a partition
    2. Select a file system type
    3. Select a host name
    4. Create host
    5. Get UUID from partition
    6. Associate UUID with host
