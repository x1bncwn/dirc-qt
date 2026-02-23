module irc_client;

import irc.client;
import irc.eventloop;
import irc.tracker;

import std.concurrency;
import std.string;
import std.conv;
import std.datetime;
import std.algorithm;
import std.array;
import std.stdio;
import std.socket;

import core.atomic;
import core.thread;
import core.time;

import mainwindow : MainWindow;
import models;
import logging;

shared static bool messagesPending = false;

class MyIRCClient : IrcClient
{
    import qt.core.object : QObject;

    Tid guiTid;
    string serverName;
    bool clientRunning = true;
    IrcTracker tracker;

    private shared(MainWindow) m_window;

    this(string server, Tid guiTid, shared(MainWindow) window, Socket socket = null)
    {
        if (socket is null) {
            super();
        } else {
            super(socket);
        }

        this.guiTid = guiTid;
        this.serverName = server;
	this.m_window = window;

        this.nickName = defaultNick;
        this.userName = defaultNick;
        this.realName = "D IRC User";

        tracker = track(this);

        setupCallbacks();
        logToTerminal("MyIRCClient created for " ~ server, "INFO", "irc");
    }

    // Formatting helpers
    private string formatDuration(int seconds) const pure {
        if (seconds < 60) {
            return to!string(seconds) ~ " second" ~ (seconds == 1 ? "" : "s");
        } else if (seconds < 3600) {
            int minutes = seconds / 60;
            return to!string(minutes) ~ " minute" ~ (minutes == 1 ? "" : "s");
        } else if (seconds < 86400) {
            int hours = seconds / 3600;
            return to!string(hours) ~ " hour" ~ (hours == 1 ? "" : "s");
        } else {
            int days = seconds / 86400;
            return to!string(days) ~ " day" ~ (days == 1 ? "" : "s");
        }
    }

    private string formatSignonTime(string signonTime) const {
        import std.datetime : SysTime;
        import std.format : format;
        import std.conv : to;
        import std.string : capitalize;

        try {
            long timestamp = signonTime.to!long;
            auto signonDate = SysTime.fromUnixTime(timestamp);
            auto localTime = signonDate.toLocalTime();
            auto localZone = localTime.timezone.dstInEffect(localTime.stdTime) ? localTime.timezone.dstName : localTime.timezone.stdName;

            return format("%s %s %02d %02d:%02d:%02d %s %04d",
                localTime.dayOfWeek.to!string[0..3].capitalize,
                localTime.month.to!string[0..3].capitalize,
                localTime.day,
                localTime.hour,
                localTime.minute,
                localTime.second,
                localZone,
                localTime.year
            );
        } catch (Exception e) {
            return signonTime;
        }
    }

    // Setup callbacks
    private void setupCallbacks()
    {
        onConnect ~= () {
            sendSystemMessage("Connected to " ~ serverName);
            tracker.start();
        };

        onTopic ~= (in char[] channel, in char[] topic) {
            sendTopicMessage(channel.idup, topic.idup);
        };

        onNickChange ~= (IrcUser user, in char[] newNick) {
            string oldNick = user.nickName.idup;
            string msgText = "is now known as " ~ newNick.idup;

	    // Send to all channels where the user was present
	    if (auto userData = tracker.findUser(oldNick)) {
		foreach (channel; userData.channels) {
		    sendChatMessage(channel, oldNick, msgText, false, false, "nick");
		}
	    }
        };

        onJoin ~= (IrcUser user, in char[] channel) {
            string nickname = user.nickName.idup;
            string chan = channel.idup;
            if (nickname == nickName.idup)
            {
                sendSystemMessage("Successfully joined " ~ chan);
                sendChannelUpdate(chan, "join");
            }
            else
            {
                sendChatMessage(chan, nickname, "joined the channel", false, false, "join");
            }
        };

        onPart ~= (IrcUser user, in char[] channel) {
            string nickname = user.nickName.idup;
            string chan = channel.idup;

            if (nickname == nickName.idup)
            {
                sendChannelUpdate(chan, "part");
            }
            else
            {
                sendChatMessage(chan, nickname, "left the channel", false, false, "part");
            }
        };

        onQuit ~= (IrcUser user, in char[] reason) {
            string nickname = user.nickName.idup;
            string msgText = "quit";
            if (reason.length > 0)
            {
                msgText ~= ": " ~ reason.idup;
            }

	    // Get channels this user was in
	    if (auto userData = tracker.findUser(nickname)) {
	    	foreach (channel; userData.channels) {
		    sendChatMessage(channel, nickname, msgText, false, false, "quit");
		}
	    }
        };

        onNotice ~= (IrcUser user, in char[] target, in char[] message) {
            string nickname = user.nickName.idup;
            string channel = target.idup;
            if (channel.length > 0 && channel[0] == ':')
            {
                channel = channel[1 .. $];
            }
            sendChatMessage(channel, nickname, message.idup, false, true);
        };

        onMessage ~= (IrcUser user, in char[] target, in char[] message) {
            string nickname = user.nickName.idup;
            string channel = target.idup;
            string msgStr = message.idup;

            bool isAction = false;
            if (msgStr.length > 0 && msgStr[0] == '\x01' && msgStr.endsWith("\x01"))
            {
                if (msgStr.length >= 8 && msgStr[1 .. 8] == "ACTION ")
                {
                    isAction = true;
                    msgStr = msgStr[8 .. msgStr.length - 1];
                }
            }

            sendChatMessage(channel, nickname, msgStr, isAction);
        };

        onWhoisReply ~= (IrcUser user, in char[] realName) {
            string header = "--- WHOIS for " ~ user.nickName.idup ~ " ---";
            sendSystemMessage(header);
            string line = user.nickName.idup ~ " [" ~ user.userName.idup ~ "@" ~ user.hostName.idup ~ "] " ~ realName.idup;
            sendSystemMessage(line, SystemMsgType.whois);
        };

        onWhoisServerReply ~= (in char[] nick, in char[] serverHostName, in char[] serverInfo) {
            string line = serverHostName.idup;
            if (serverInfo.length > 0) line ~= " (" ~ serverInfo.idup ~ ")";
            sendSystemMessage(line, SystemMsgType.whois);
        };

        onWhoisOperatorReply ~= (in char[] nick) {
            sendSystemMessage("This user is an IRC operator", SystemMsgType.whois);
        };

        onWhoisIdleReply ~= (in char[] nick, int idleTime, in char[] signonTime) {
            string idle = "Idle: " ~ formatDuration(idleTime);
            sendSystemMessage(idle, SystemMsgType.whois);
            if (signonTime.length > 0) {
                string signon = "Signed on: " ~ formatSignonTime(signonTime.idup);
                sendSystemMessage(signon, SystemMsgType.whois);
            }
        };

        onWhoisChannelsReply ~= (in char[] nick, in char[][] channels) {
            string line = "Channels: ";
            foreach (channelGroup; channels)
            {
                line ~= channelGroup.idup ~ " ";
            }
            sendSystemMessage(line.stripRight(), SystemMsgType.whois);
        };

        onWhoisAccountReply ~= (in char[] nick, in char[] accountName) {
            sendSystemMessage("Logged in as: " ~ accountName.idup, SystemMsgType.whois);
        };

        onWhoisAwayReply ~= (in char[] nick, in char[] awayMessage) {
            sendSystemMessage("Away: " ~ awayMessage.idup, SystemMsgType.whois);
        };

        onWhoisHelpOpReply ~= (in char[] nick) {
            sendSystemMessage("Available for help", SystemMsgType.whois);
        };

        onWhoisSpecialReply ~= (in char[] nick, in char[] specialInfo) {
            sendSystemMessage("Special: " ~ specialInfo.idup, SystemMsgType.whois);
        };

        onWhoisActuallyReply ~= (in char[] nick, in char[] actualHost, in char[] description) {
            string line = "Actually: " ~ actualHost.idup;
            if (description.length > 0) {
                line ~= " (" ~ description.idup ~ ")";
            }
            sendSystemMessage(line, SystemMsgType.whois);
        };

        onWhoisHostReply ~= (in char[] nick, in char[] hostInfo) {
            sendSystemMessage("Host info: " ~ hostInfo.idup, SystemMsgType.whois);
        };

        onWhoisModesReply ~= (in char[] nick, in char[] modesInfo) {
            sendSystemMessage("Modes: " ~ modesInfo.idup, SystemMsgType.whois);
        };

        onWhoisSecureReply ~= (in char[] nick, in char[] secureInfo) {
            sendSystemMessage(nick.idup ~ " " ~ secureInfo.idup, SystemMsgType.whois);
        };

        onWhoisEnd ~= (in char[] nick) {
            sendSystemMessage("--- End of WHOIS ---", SystemMsgType.whois);
        };

        onMotdStart ~= (in char[] text) { sendSystemMessage(text.idup, SystemMsgType.motd); };
        onMotd ~= (in char[] line) { sendSystemMessage(line.idup, SystemMsgType.motd); };
        onMotdEnd ~= (in char[] text) { sendSystemMessage(text.idup, SystemMsgType.motd); };
        onNoMotd ~= (in char[] text) { sendSystemMessage(text.idup, SystemMsgType.motd); };

        onServerInfo ~= (in char[] code, in char[] text) {
            sendSystemMessage(text.idup);
        };

        onNickInUse ~= (in char[] requestedNick) {
            string newNick = requestedNick.idup ~ "_";
            sendSystemMessage("Nickname " ~ requestedNick.idup ~ " is in use, trying " ~ newNick, SystemMsgType.warning);
            return newNick;
        };
    }

    /*private void sendToGui(IrcToGuiMessage msg)
    {
        import std.concurrency : send;

        send(guiTid, msg);

	atomicStore(messagePending, true);
    }*/

    private void sendToGui(IrcToGuiMessage msg)
    {
        import std.concurrency : send;
        import qt.core.objectdefs : QMetaObject, QGenericReturnArgument, QGenericArgument;

        send(guiTid, msg);

        if (!atomicExchange(&messagesPending, true)) {
            QMetaObject.invokeMethod(
                cast(QObject)m_window,
                "processPendingMessages",
                QGenericReturnArgument(),
                QGenericArgument(),
                QGenericArgument(),
                QGenericArgument(),
                QGenericArgument(),
                QGenericArgument(),
                QGenericArgument(),
                QGenericArgument(),
                QGenericArgument(),
                QGenericArgument(),
                QGenericArgument()
            );
        }
    }

    private void sendChatMessage(string channel, string rawNickname, in char[] msgBody, bool isAction = false, bool isNotice = false, string customType = "")
    {
        auto now = Clock.currTime();
        string timeStr = "[" ~ format("%02d:%02d", now.hour, now.minute) ~ "]";

        string prefixStr = "";
        if (channel.length > 0 && channel[0] == '#')
        {
            char prefixChar = '\0';
            if (auto user = tracker.findUser(rawNickname)) {
                prefixChar = user.getHighestPrefix(channel);
            }
            if (prefixChar)
            {
                prefixStr = [prefixChar].idup;
            }
        }

        string messageType = customType.length > 0 ? customType : (isAction ? "action" : (isNotice ? "notice" : "message"));

        ChatMessage chat = ChatMessage(serverName, channel, timeStr, rawNickname, prefixStr, messageType, msgBody.idup);
        sendToGui(IrcToGuiMessage.fromChat(chat));
    }

    private void sendChannelUpdate(string channel, string action)
    {
        ChannelUpdate update = ChannelUpdate(serverName, channel, action);
        sendToGui(IrcToGuiMessage.fromUpdate(update));
    }

    private void sendSystemMessage(in char[] text)
    {
        sendToGui(IrcToGuiMessage.fromSystem(text.idup));
    }

    private void sendSystemMessage(in char[] text, SystemMsgType msgType)
    {
        sendToGui(IrcToGuiMessage.fromSystem(text.idup, msgType));
    }

    private void sendTopicMessage(string channel, in char[] topic)
    {
        sendToGui(IrcToGuiMessage.fromTopic(ChannelTopic(serverName, channel, topic.idup)));
    }

    void performQuit(string message)
    {
        try
        {
            quit(message);
        }
        catch (Exception e)
        {
            logToTerminal("Error during quit: " ~ e.msg, "ERROR", "irc");
        }
        clientRunning = false;
    }
}

void runIrcServer(string server, Tid guiTid, shared(MainWindow) window)
{
    logToTerminal("Creating IRC client for " ~ server, "INFO", "irc");

    try
    {
        import std.socket : InternetAddress;

        string host;
        ushort port = defaultPort;
        bool useSsl = false;

        auto colonPos = server.indexOf(":");
        if (colonPos != -1)
        {
            host = server[0 .. colonPos];
            port = to!ushort(server[colonPos + 1 .. $]);
        } else {
            host = server;
        }

        if (port == 6697 || port == 7000 || port == 9999) {
            useSsl = true;
            logToTerminal("Auto-detected SSL from port " ~ to!string(port), "INFO", "irc");
        }

        MyIRCClient client;

        if (useSsl) {
            import ssl.socket : SslSocket;
            import std.socket : AddressFamily;

            try {
                auto sslSocket = new SslSocket(AddressFamily.INET);
                client = new MyIRCClient(server, guiTid, window, sslSocket);
                logToTerminal("Using SSL connection for " ~ server, "INFO", "irc");
            } catch (Exception e) {
                logToTerminal("Failed to create SSL socket: " ~ e.msg, "ERROR", "irc");
                client = new MyIRCClient(server, guiTid, window);
                logToTerminal("Falling back to non-SSL connection", "WARNING", "irc");
            }
        } else {
            client = new MyIRCClient(server, guiTid, window);
        }

        auto address = new InternetAddress(host, port);
        client.connect(address);

        logToTerminal("IRC client connected, waiting for commands...", "INFO", "irc");

        auto eventLoop = new IrcEventLoop();
        eventLoop.add(client);

        import core.sync.mutex : Mutex;

        Mutex queueMutex = new Mutex();
        alias MessageTask = void delegate();
        MessageTask[] messageQueue;

        eventLoop.setAsyncCallback({
            queueMutex.lock();
            scope (exit) queueMutex.unlock();

            while (!messageQueue.empty)
            {
                try
                {
                    auto task = messageQueue.front;
                    messageQueue.popFront();
                    task();
                }
                catch (Exception e)
                {
                    logToTerminal("Error in async task: " ~ e.msg, "ERROR", "irc");
                }
            }
        });

        void queueTask(void delegate() task)
        {
            queueMutex.lock();
            scope (exit) queueMutex.unlock();
            messageQueue ~= task;
            eventLoop.sendAsync();
        }

        // Start event loop in a separate thread
        Thread eventLoopThread = new Thread({
            logToTerminal("Event loop thread starting", "DEBUG", "irc");
            try
            {
                eventLoop.run();
            }
            catch (Exception e)
            {
                logToTerminal("Event loop error: " ~ e.msg, "ERROR", "irc");
            }
            logToTerminal("Event loop thread exiting", "DEBUG", "irc");
        });
        eventLoopThread.start();

        bool running = true;
        while (running && client.clientRunning)
        {
            bool gotMessage = receiveTimeout(Duration.zero, (GuiToIrcMessage msg) {
                try
                {
                    if (msg.type == GuiToIrcMessage.Type.Message && msg.text.length > 0)
                    {
                        if (msg.channel.length > 0)
                        {
                            // Check for action (CTCP ACTION)
                            bool isAction = false;
                            string displayText = msg.text;
                            if (msg.text.length > 0 && msg.text[0] == '\x01' && msg.text.endsWith("\x01"))
                            {
                                if (msg.text.length >= 8 && msg.text[1 .. 8] == "ACTION ")
                                {
                                    isAction = true;
                                    displayText = msg.text[8 .. msg.text.length - 1];
                                }
                            }

                            client.sendChatMessage(msg.channel, client.nickName.idup, displayText, isAction, false, isAction ? "action" : "message");

                            // Queue the actual send operation
                            queueTask({
                                try {
                                    client.send(msg.channel, msg.text);
                                } catch (Exception e) {
                                    logToTerminal("Error sending message: " ~ e.msg, "ERROR", "irc");
                                }
                            });
                        }
                    }
                    else if (msg.type == GuiToIrcMessage.Type.UpdateChannels)
                    {
                        if (msg.action == "join" && msg.channel.length > 0)
                        {
                            queueTask({
                                try {
                                    client.join(msg.channel);
                                } catch (Exception e) {
                                    logToTerminal("Error joining channel: " ~ e.msg, "ERROR", "irc");
                                }
                            });
                        }
                        else if (msg.action == "part" && msg.channel.length > 0)
                        {
                            queueTask({
                                try {
                                    client.part(msg.channel);
                                } catch (Exception e) {
                                    logToTerminal("Error leaving channel: " ~ e.msg, "ERROR", "irc");
                                }
                            });
                        }
                        else if (msg.action == "whois" && msg.channel.length > 0)
                        {
                            queueTask({ client.queryWhois(msg.channel); });
                        }
                        else if (msg.action == "quit")
                        {
                            queueTask({
                                client.performQuit("d-irc client exiting");
                                running = false;
                                eventLoop.breakLoop();
                            });
                        }
                    }
                }
                catch (Exception e)
                {
                    logToTerminal("Error: " ~ e.msg, "ERROR", "irc");
                    client.sendSystemMessage("Error: " ~ e.msg);
                }
                return true;
            });

            // Sleep briefly if no messages
            if (!gotMessage)
            {
                Thread.sleep(10.msecs);
            }
        }

        eventLoopThread.join();
        logToTerminal("IRC client thread exiting", "INFO", "irc");
    }
    catch (Exception e)
    {
        logToTerminal("Error: " ~ e.msg, "ERROR", "irc");
        std.concurrency.send(guiTid, IrcToGuiMessage.fromSystem("Connection error: " ~ e.msg));
    }
}
