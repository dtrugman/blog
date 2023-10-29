---
title: "Meet RCI and the amazing proc connector"
author: Daniel Trugman
date: 2021-02-21T09:00:00-00:00
categories: ['Programming','Internals','Linux','CPP']
draft: false
---

This blog post is about a Linux mechanism called proc connector that allows you to get asynchronous notifications about different events on a Linux OS.

This post is an important milestone for me: **My first post to be officially released in my new, self-owned blog [trugman-internals](https://trugman-internals.com)**, pretty exciting!

But that's not all, this post marks the beginning of a new library: **[Runtime Collection Interfaces (RCI)](https://github.com/dtrugman/rci)**. An awesome request from a Redditor gave birth to the idea of wrapping additional mechanisms in Linux. The proc connector is hopefully going to be the first of many useful APIs I can help make more accessible.

There's an abundance of standard infrastructures in Linux, each written by a different person, for a different reason and providing a different kind of information. Unfortunately, some of those useful APIs are not very well documented. And I would definitely say that the proc connector belongs to that category.

Before I started writing this, I looked for any existing resources, but couldn't find anything. Some projects on Github used it, but there was nothing to help lost souls wondering around and looking for a worthy explanation. That was my cue.

## What is the goal of the proc connector

This mechanism was added in Linux kernel version 2.6.15, and the [commit](https://github.com/torvalds/linux/commit/9f46080c41d5f3f7c00b4e169ba4b0b2865258bf) message says:

> This patch adds a connector that reports fork, exec, id change, and exit events for all processes to userspace. It replaces the fork_advisor patch that ELSA is currently using. Applications that may find these events useful include accounting/auditing (e.g. ELSA), system activity monitoring (e.g. top), security, and resource management (e.g. CKRM).

Since then, the API added some new reported event types, but the idea stayed the same: A process in user-space can "register" with the connector and request real-time notifications about events happening on the system.

## Reported events

As of the time of writing, these are the events reported by the proc connector and the information they include:

* Fork events
  * Parent thread-id and process-id
  * Child thread-id and process-id
* Exec events
  * Process thread-id and process-id
* Exit events
  * Process thread-id and process-id
  * Exit code and signal
  * Parent thread-id and process-id (Starting from Linux kernel 4.18.0)
* GID/UID-change events
  * Process thread-id and process-id
  * New real and effective UIDs
* SID-change events
  * Process thread-id and process-id
* Ptrace events (Starting from Linux kernel 3.0.0)
  * Tracee thread-id and process-id
  * Tracer thread-id and process-id
* Comm-change events (Starting from Linux kernel 3.1.0)
  * Process thread-id and process-id
  * New comm
* Coredump events ((Starting from Linux kernel 3.10.0)
  * Process thread-id and process-id
  * Parent thread-id and process-id (Starting from Linux kernel 4.18.0)

If you are not afraid of some Linux kernel code, only source of truth is the `proc_event` struct. You can always take find the latest version using [Bootlin's Elixir](https://elixir.bootlin.com/linux/latest/A/ident/proc_event).

## Kernel connector code

I felt that diving into the kernel code here might be overwhelming and not very useful. If you really wanna see how and/or where the kernel sends these events, take a look at [`cn_proc.c`](https://elixir.bootlin.com/linux/latest/source/drivers/connector/cn_proc.c). This file contains all the event generation methods.

If you wanna dig in some more and find exactly where in the scheduler code the kernel calls the fork generation event (for example), Bootlin's Elixir platform is here to help you with just that. Searching for all the references to [`proc_fork_connector`](https://elixir.bootlin.com/linux/latest/C/ident/proc_fork_connector) will get you to the `copy_process`, where the kernel generates the event.

## Communication medium

The user-space process communicates with the kernel through a [netlink](https://man7.org/linux/man-pages/man7/netlink.7.html). Netlink sockets are used to transfer information between the kernel and user-space processes using the beloved BSD sockets API. They are datagram-oriented (just like UDP) and support multicasting from the kernel to user-space, making them highly efficient when multiple consumers are involved.

Just like any other socket-based communication. Our user-space process will open a socket and bind it:

```c
int socket_create()
{
    int sock = socket(PF_NETLINK, SOCK_DGRAM, NETLINK_CONNECTOR);
    if (sock == -1) {
        return -errno;
    }

    sockaddr_nl bind_addr;
    bind_addr.nl_family = AF_NETLINK;
    bind_addr.nl_groups = CN_IDX_PROC;
    bind_addr.nl_pid    = gettid();

    int err = bind(sock, (struct sockaddr*)&bind_addr, sizeof(bind_addr));
    if (err) {
        close(sock);
        return -errno;
    }

    return sock;
}
```

If you are used to using sockets, you can probably spot the minimal differences right away:

* We create a `PF_NETLINK` socket and use `NETLINK_CONNECTOR` for protocol
* We use a `sockaddr_nl` struct for the address using `AF_NETLINK` as an address family

But the two crucial pieces of the puzzle here are actually the following ones:

* The address group is `CN_IDX_PROC` - This is where we actually state we don't want some netlink, but specifically the proc connector.
* We need to assign a unique identifier (`nl_pid`) to the listener. We can use our process’ PID, but if for any weird reason another thread in the same process wants to use the proc connector as well, and tries to bind a netlink with the same `nl_pid`, it will fail. So the best suggestion is to use the thread ID that will be listening to the incoming events from the netlink.

## [Un]registration

We now have a bound socket, but the proc connector still won't send notifications to us. The contract demands user-space applications send a registration message when they want to start receiving notification messages and an unregistration message when they want them to stop.

These two values, grouped under the `proc_cn_mcast_op` are the only "messages" a user-space application should ever send to the proc connector:

```c
enum proc_cn_mcast_op {
    PROC_CN_MCAST_LISTEN = 1,
    PROC_CN_MCAST_IGNORE = 2
};
```

IMHO, the actual code to send a netlink message always seems overcomplicated and way too long, but well, you can't get everything in life.

Instead of showing the code and adding an explanation afterwards, I added inline comments that hopefully make everything clear.

> Code uses C style, so that C developers can use these snippets as well for their projects

```c
int socket_send_op(enum proc_cn_mcast_op op)
{
    // The op is the "data" we're going to send
    void* data  = &op;
    size_t size = sizeof(op);

    // Since we know how big is our "data", allocate a buffer on our stack.
    // We will create the netlink message in-place.
    uint8_t buffer[1024] = { 0 };

    // Treat our buffer as if it starts with a netlink message header
    struct nlmsghdr* nl_hdr = (struct nlmsghdr*)buffer;
    // Get the location of the message from the netlink message header
    struct cn_msg* nl_msg = (struct cn_msg*)(NLMSG_DATA(nl_hdr));

    // Fill in some fields in the netlink message header
    nl_hdr->nlmsg_len  = NLMSG_SPACE(NLMSG_LENGTH(sizeof(*nl_msg) + size));
    nl_hdr->nlmsg_type = NLMSG_DONE;
    nl_hdr->nlmsg_pid  = gettid();

    nl_msg->id.idx = CN_IDX_PROC;
    nl_msg->id.val = CN_VAL_PROC;
    nl_msg->len    = size;

    // Copy our "data" into the netlink message
    memcpy(nl_msg->data, data, size);

    // Wrap the netlink message using an iovec
    struct iovec iov = {};
    iov.iov_base     = (void*)nl_hdr;
    iov.iov_len      = nl_hdr->nlmsg_len;

    // Create an object to describe the proc connector's address
    // Notice the 0, this is the kernel's identifier
    sockaddr_nl kernel_addr;
    kernel_addr.nl_family = AF_NETLINK;
    kernel_addr.nl_groups = CN_IDX_PROC;
    kernel_addr.nl_pid    = 0;

    // Send the iovec as a message
    // This is required because we need to explicitly state the address
    struct msghdr msg = {};
    msg.msg_name      = (void*)&kernel_addr;
    msg.msg_namelen   = sizeof(kernel_addr);
    msg.msg_iov       = &iov;
    msg.msg_iovlen    = 1;

    ssize_t bytes = sendmsg(_socket, &msg, 0);
    if (bytes < 0 || (size_t)bytes != nl_hdr->nlmsg_len)
    {
        return -errno;
    }

    return 0;
}
```

## Receiving events

Now that everything is ready, we can start receiving events.

Since we're only receiving from a single socket, we'll go with the classic design - A single thread that loops on a `recvfrom` call. Again, the code is not for the faint-hearted, but some inline comments are definitely going to make the difference.

> My ultimate goal here was to make this code clearer for the reader. If you want the cleanest design possible, I encourage you to take a look at my [implementation](https://github.com/dtrugman/rci/blob/master/src/proconn.cpp)

```c
int socket_recv(sockaddr_nl& addr, void* buffer, size_t buffer_size)
{
    // The address length is an input/output parameter for recvfrom,
    // so it has to be writable
    socklen_t addr_len = sizeof(addr);

    // Receive the netlink message into the buffer
    struct nlmsghdr* nl_hdr = (struct nlmsghdr*)buffer;

    // Actually receive the message
    ssize_t bytes = recvfrom(_socket, buffer, buffer_size, 0,
                             (sockaddr*)&addr, &addr_len);
    if (bytes <= 0) {
        return -errno;
    }

    // Make sure the message arrived from the kernel
    if (addr.nl_pid != _kernel_addr.nl_pid) {
        // Received message from unexpected source, just handle it somehow...
        return -EIO;
    }

    // While the nl_hdr points to a valid message, keep processing
    while (NLMSG_OK(nl_hdr, bytes))
    {
        // Handle NOOP and ERROR messages
        unsigned msg_type = nl_hdr->nlmsg_type;
        if (msg_type == NLMSG_NOOP)
        {
            continue;
        }
        else if (msg_type == NLMSG_ERROR || msg_type == NLMSG_OVERRUN)
        {
            return -EINVAL;
        }

        // Call our handler with the inner proc_event struct
        struct cn_msg* msg = (struct cn_msg*)(NLMSG_DATA(nl_hdr));
        dispatch_event((proc_event*)(msg->data));

        // Terminate if this was the last message
        if (msg_type == NLMSG_DONE)
        {
            break;
        }

        // Handle more messages if such exist
        nl_hdr = NLMSG_NEXT(nl_hdr, bytes);
    }

    return 0;
}

void run()
{
    // Create an object to describe the proc connector's kernel address
    // (Obviously a clean design will not declare the same address twice)
    sockaddr_nl kernel_addr;
    kernel_addr.nl_family = AF_NETLINK;
    kernel_addr.nl_groups = CN_IDX_PROC;
    kernel_addr.nl_pid    = 0;

    // Create a reusable buffer for incoming message
    uint8_t buffer[1024];
    size_t buffer_size = sizeof(buffer);

    // Run in a loop and process events till an error is encountered
    while (!socket_recv(&kernel_addr, buffer, buffer_size)
        ;
}
```

## Processing the incoming events

If you followed everything till now, you saw that we called a `dispatch_event` method with a pointer to a `proc_event` struct. This struct is a union of all smaller structs that can represent any of the reported events.

Handling it is quite easy, you just check the `event->what` member of the struct and access the right members:

```c
void dispatch_event(const proc_event* evt)
{
    switch (evt->what)
    {
        case proc_event::PROC_EVENT_FORK:
            printf("FORK %d/%d -> %d/%d",
                evt->event_data.fork.parent_pid,
                evt->event_data.fork.parent_tgid,
                evt->event_data.fork.child_pid,
                evt->event_data.fork.child_tgid);
            break;

        case proc_event::PROC_EVENT_EXEC:
            printf("EXEC %d/%d",
                evt->event_data.exec.process_pid,
                evt->event_data.exec.process_tgid);
            break;

        ...
    }
}
```

## Conclusions

The proc connector is a useful mechanism. It is indeed not the simplest one, and there are multiple ways to get it wrong, so I suggest you check out the RCI library that provider a wrapper for the proc connector. It's already tested, high-performing and provide a clean API and an easy experience.

If you want to take your code to the next level, and start gathering additional information about processes, I strongly suggest taking a look at my pfs library. It gives you the power to extract all the information you need about processes in runtime from the procfs.

Hope you enjoyed!
