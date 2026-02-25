module mainwindow;

import qt.core.coreapplication;
import qt.core.coreevent;
import qt.core.namespace;
import qt.core.object;
import qt.core.string;
import qt.core.timer;
import qt.core.variant;
import qt.gui.action;
import qt.gui.color;
import qt.gui.event;
import qt.gui.palette;
import qt.gui.textcursor;
import qt.gui.textoption;
import qt.widgets.application;
import qt.widgets.inputdialog;
import qt.widgets.mainwindow;
import qt.widgets.lineedit;
import qt.widgets.messagebox;
import qt.widgets.treewidget;
import qt.widgets.label;
import qt.widgets.widget;
import qt.widgets.ui;
import qt.helpers;
import core.stdcpp.new_;

import models;
import logging;
import irc_client;
import sidebar;
import chatarea;
import inputarea;

import std.conv;
import std.string;
import std.algorithm;
import std.array;
import std.datetime;
import std.range;
import std.math;
import std.format;
import core.time;
import core.thread;
import std.concurrency;
import std.stdio;
import std.file;

struct MainWindowUI
{
    mixin(generateUICode(import("mainwindow.ui"), "mainwindow"));
}

class MainWindow : QMainWindow
{
    mixin(Q_OBJECT_D);

private:
    MainWindowUI* ui;
    Sidebar sidebar;
    ChatArea chatArea;
    InputArea inputArea;
    QLabel statusLabel;

    // State
    string currentDisplay = "System";
    string currentServer;
    string[string][string] serverBuffers;  // [server][key] = buffer content
    string[] displayHistory;
    string[string][string] channelTopics;

    // Settings
    bool colorizeNicks = true;
    bool autoSwitchToNewChannels = true;
    bool isDarkTheme = true;
    string[string] nickColorCache;

    // IRC Threads
    Tid[string] serverThreads;

public:
    this(QWidget parent = null)
    {
        import core.stdcpp.new_;

        super(parent);

        logToTerminal("Initializing MainWindow", "INFO", "main");

        this.ui = cpp_new!(typeof(*ui));
        ui.setupUi(this);

        sidebar = cpp_new!Sidebar(this);
        chatArea = cpp_new!ChatArea(this);
        inputArea = cpp_new!InputArea(this);

        statusLabel = cpp_new!QLabel("Disconnected", this);
        ui.statusbar.addWidget(statusLabel);

        ui.splitter.insertWidget(0, sidebar);
        ui.splitter.insertWidget(1, chatArea);
        ui.verticalLayout.insertWidget(1, inputArea);
        ui.verticalLayout.setStretch(0, 1);
        ui.verticalLayout.setStretch(1, 0);

        // Initialize system buffer
        serverBuffers["System"] = null;
        serverBuffers["System"]["System"] = "";
        chatArea.setDisplay("System");

        setupSignals();

        // Set dark theme by default
        setApplicationTheme(true);

        appendWelcomeMessage();

        statusLabel.setText(QString("Disconnected"));

        logToTerminal("MainWindow initialized", "INFO", "main");
    }

    ~this()
    {
        import core.stdcpp.new_;

        cpp_delete(ui);
    }

    @QSlot final void processPendingMessages()
    {
        import core.atomic : atomicExchange;

        if (serverThreads.length == 0)
            return;
        do
        {
            bool gotMessage = true;
            while (gotMessage)
            {
                gotMessage = receiveTimeout(Duration.zero,(IrcToGuiMessage msg)
                {
                    logToTerminal("Processing message type: "~ to!string(msg.type), "DEBUG", "main");
                    processIrcMessage(msg);
                    return true;
                });
            }

        } while (atomicExchange(&messagesPending, false));
    }

    void sendToIrcThread(string server, GuiToIrcMessage msg)
    {
        if (server in serverThreads)
        {
            logToTerminal("Sending to IRC thread: " ~ server ~ " type: " ~
                            to!string(msg.type), "DEBUG", "main");
            send(serverThreads[server], msg);
        }
    }

private:
    void setupSignals()
    {
        import core.stdcpp.new_;

        QObject.connect(ui.actionConnect.signal!"triggered", this.slot!"onConnectAction");
        QObject.connect(ui.actionDisconnect.signal!"triggered", this.slot!"onDisconnectAction");
        QObject.connect(ui.actionQuit.signal!"triggered", this.slot!"onQuitAction");
        QObject.connect(ui.actionDark.signal!"triggered", this.slot!"onDarkThemeAction");
        QObject.connect(ui.actionLight.signal!"triggered", this.slot!"onLightThemeAction");
        QObject.connect(ui.actionAbout.signal!"triggered", this.slot!"onAboutAction");

        QObject.connect(sidebar.signal!"itemClicked", this.slot!"onChannelSelected");
        QObject.connect(inputArea.signal!"sendMessage", this.slot!"onInputMessage");
    }

protected:
    override extern(C++) void closeEvent(QCloseEvent event)
    {
        logToTerminal("Close event triggered", "INFO", "main");
        disconnectAllServers();
        Thread.sleep(100.msecs);
        event.accept();
    }

private /+ slots +/:
    @QSlot final void onConnectAction()
    {
        logToTerminal("Connect action triggered", "INFO", "main");

        bool ok;
        QString server = QInputDialog.getText(this,
            QString("Connect"),
            QString("Server address:"),
            qt.widgets.lineedit.QLineEdit.EchoMode.Normal,
            QString(defaultServer),
            &ok);

        if (ok && server.length() > 0)
        {
            auto data = server.toUtf8().constData();
            string serverStr = data[0 .. server.toUtf8().length()].idup;
            logToTerminal("Connecting to: " ~ serverStr, "INFO", "main");
            startConnection(serverStr);
        }
    }

    @QSlot final void onDisconnectAction()
    {
        logToTerminal("Disconnect action triggered", "INFO", "main");
        disconnectFromServer();
    }

    @QSlot final void onQuitAction()
    {
        logToTerminal("Quit action triggered", "INFO", "main");
        disconnectAllServers();
        Thread.sleep(100.msecs);
        QApplication.quit();
    }

    @QSlot final void onDarkThemeAction()
    {
        logToTerminal("Dark theme action triggered", "INFO", "main");
        setApplicationTheme(true);
    }

    @QSlot final void onLightThemeAction()
    {
        logToTerminal("Light theme action triggered", "INFO", "main");
        setApplicationTheme(false);
    }

    @QSlot final void onAboutAction()
    {
        string aboutText = "<h2>D IRC Client</h2>" ~
                          "<p>Version 1.0</p>" ~
                          "<p>Qt IRC client</p>";
        QMessageBox.about(this, QString("About D IRC Client"), QString(aboutText));
    }

    @QSlot final void onChannelSelected(QTreeWidgetItem item, int column)
    {
        auto displayData = item.text(0).toUtf8().constData();
        string display = displayData[0 .. item.text(0).toUtf8().length()].idup;

        auto typeData = item.data(0, qt.core.namespace.ItemDataRole.UserRole).toString().toUtf8().constData();
        string itemType = typeData[0 .. item.data(0, qt.core.namespace.ItemDataRole.UserRole).toString().toUtf8().length()].idup;

        logToTerminal("Channel selected: " ~ display ~ " type: " ~ itemType, "INFO", "main");

        if (itemType == "server")
        {
            currentServer = display;
            currentDisplay = display;
            chatArea.setDisplay(display);

            // Load server buffer (keyed by server name only)
            if (display in serverBuffers && display in serverBuffers[display])
            {
                chatArea.setContent(serverBuffers[display][display]);
            }
	    statusLabel.setText(QString("Connected to " ~ display));
        }
        else if (itemType == "channel")
        {
            auto parent = item.parent();
            if (parent !is null)
            {
                auto parentData = parent.text(0).toUtf8().constData();
                currentServer = parentData[0 .. parent.text(0).toUtf8().length()].idup;
                currentDisplay = display;

                chatArea.setDisplay(display);

                // Load channel buffer using qualified key (server:channel)
                string bufferKey = currentServer ~ ":" ~ display;
                if (currentServer in serverBuffers && bufferKey in serverBuffers[currentServer])
                {
                    chatArea.setContent(serverBuffers[currentServer][bufferKey]);
                }
		statusLabel.setText(QString("Channel " ~ display ~ " on " ~ currentServer));
            }
        }
    }

    @QSlot final void onInputMessage(QString text)
    {
        auto data = text.toUtf8().constData();
        string msg = data[0 .. text.toUtf8().length()].idup;
        inputArea.clear();

        if (msg.length == 0) return;

        logToTerminal("Input received: " ~ msg, "INFO", "main");

        if (currentServer.length == 0 || !(currentServer in serverThreads))
        {
            if (msg.startsWith("/connect"))
            {
                handleCommand(msg);
                return;
            }
            appendSystemMessage("Not connected to any server.");
            return;
        }

        if (msg.length > 1 && msg[0] == '/')
        {
            handleCommand(msg);
            return;
        }

        if (currentDisplay == currentServer)
        {
            auto spacePos = msg.indexOf(" ");
            if (spacePos != -1)
            {
                auto recipient = msg[0 .. spacePos].strip();
                auto message = msg[spacePos .. $].strip();
                logToTerminal("Private message to: " ~ recipient, "DEBUG", "main");
                auto ircMsg = GuiToIrcMessage(GuiToIrcMessage.Type.Message, recipient, message, "");
                sendToIrcThread(currentServer, ircMsg);
            }
            else
            {
                appendSystemMessage("Usage: nick message (for private messages)");
            }
        }
        else if (currentDisplay.startsWith("#"))
        {
            logToTerminal("Channel message to: " ~ currentDisplay, "DEBUG", "main");
            auto ircMsg = GuiToIrcMessage(GuiToIrcMessage.Type.Message, currentDisplay, msg, "");
            sendToIrcThread(currentServer, ircMsg);
        }
        else
        {
            appendSystemMessage("Cannot send message to this tab.");
        }
    }

private:
    void setApplicationTheme(bool darkMode)
    {
        import std.file;
        import std.string;
        import std.stdio;

        isDarkTheme = darkMode;
        nickColorCache.clear();

        string themeFile;
        if (darkMode)
            themeFile = "views/themes/dark.qss";
        else
            themeFile = "views/themes/light.qss";

        logToTerminal("Loading theme: " ~ themeFile, "INFO", "main");

        if (exists(themeFile))
        {
            auto data = read(themeFile);
            string content = cast(string)data;

            auto app = cast(QApplication)QCoreApplication.instance();
            if (app !is null)
            {
                app.setStyleSheet(QString(content));
                logToTerminal("Theme applied: " ~ (darkMode ? "dark" : "light"), "INFO", "main");
            }
        }

        // Reload current buffer with new theme colors
        if (currentServer in serverBuffers)
        {
            if (currentDisplay == currentServer)
            {
                if (currentServer in serverBuffers[currentServer])
                    chatArea.setContent(serverBuffers[currentServer][currentServer]);
            }
            else
            {
                string bufferKey = currentServer ~ ":" ~ currentDisplay;
                if (bufferKey in serverBuffers[currentServer])
                    chatArea.setContent(serverBuffers[currentServer][bufferKey]);
            }
        }

        appendSystemMessage("Switched to " ~ (darkMode ? "dark" : "light") ~ " theme");
    }

    void startConnection(string server)
    {
        if (server in serverThreads)
        {
            appendSystemMessage("Already connected to " ~ server ~ ".");
            return;
        }

        logToTerminal("Starting connection to: " ~ server, "INFO", "main");

        auto tid = spawn(&runIrcServer, server, thisTid, cast(shared)this);
        serverThreads[server] = tid;

        // Initialize server buffer (keyed by server name only)
        if (!(server in serverBuffers))
            serverBuffers[server] = null;
        if (!(server in serverBuffers[server]))
            serverBuffers[server][server] = "";

        sidebar.addServer(server);

        currentDisplay = server;
        currentServer = server;

        // Load server buffer
        if (server in serverBuffers && server in serverBuffers[server])
        {
            chatArea.setContent(serverBuffers[server][server]);
        }

        chatArea.setDisplay(server);

        appendSystemMessage("Connecting to " ~ server ~ "...");
        statusLabel.setText(QString("Connecting to " ~ server ~ "..."));

        logToTerminal("Statusbar set to: Connecting to " ~ server, "DEBUG", "main");

        if (!displayHistory.canFind(server))
            displayHistory ~= server;
    }

    void disconnectFromServer()
    {
        if (currentServer.length == 0 || !(currentServer in serverThreads))
            return;

        logToTerminal("Disconnecting from: " ~ currentServer, "INFO", "main");

        auto tid = serverThreads[currentServer];
        auto msg = GuiToIrcMessage(GuiToIrcMessage.Type.UpdateChannels, "", "", "quit");
        send(tid, msg);

        Thread.sleep(100.msecs);

        sidebar.removeServer(currentServer);
        serverThreads.remove(currentServer);

        appendSystemMessage("Disconnected from " ~ currentServer ~ ".");
        statusLabel.setText(QString("Disconnected"));

        logToTerminal("Statusbar set to: Disconnected", "DEBUG", "main");

        currentServer = "";
        currentDisplay = "System";

        // Load system buffer
        if ("System" in serverBuffers && "System" in serverBuffers["System"])
        {
            chatArea.setContent(serverBuffers["System"]["System"]);
        }
        chatArea.setDisplay("System");
    }

    void disconnectAllServers()
    {
        logToTerminal("Disconnecting from all servers", "INFO", "main");

        foreach (server, tid; serverThreads)
        {
            auto msg = GuiToIrcMessage(GuiToIrcMessage.Type.UpdateChannels, "", "", "quit");
            send(tid, msg);
        }

        Thread.sleep(150.msecs);

        sidebar.clear();
        serverThreads = null;

        appendSystemMessage("Disconnected from all servers.");
        statusLabel.setText(QString("Disconnected"));

        logToTerminal("Statusbar set to: Disconnected", "DEBUG", "main");

        currentDisplay = "System";
        currentServer = "";

        // Load system buffer
        if ("System" in serverBuffers && "System" in serverBuffers["System"])
        {
            chatArea.setContent(serverBuffers["System"]["System"]);
        }
        chatArea.setDisplay("System");
    }

    void processIrcMessage(IrcToGuiMessage msg)
    {
        final switch (msg.type)
        {
            case IrcToGuiType.chatMessage:
                auto data = msg.chat;
                string server = data.server;
                string channel = data.channel.length > 0 ? data.channel : data.server;
                string display = channel;

                logToTerminal("Chat message for: " ~ display ~ " from: " ~ data.rawNick ~ " on server: " ~ server, "DEBUG", "main");

                // Initialize server buffer if needed
                if (!(server in serverBuffers))
                    serverBuffers[server] = null;

                // Use qualified key for channel messages
                string bufferKey = server ~ ":" ~ channel;
                if (!(bufferKey in serverBuffers[server]))
                    serverBuffers[server][bufferKey] = "";

                string displayNick = data.prefix ~ data.rawNick;
                string formatted = formatChatMessage(data.timestamp, data.prefix, displayNick, data.messageType, data.body, display);

                // Append to the correct server+channel buffer
                serverBuffers[server][bufferKey] ~= formatted;

                // Show in UI if this is the current server and display
                if (server == currentServer && display == currentDisplay)
                {
                    chatArea.appendMessage(display, formatted);
                }
                break;

            case IrcToGuiType.channelUpdate:
                auto u = msg.channelUpdate;
                logToTerminal("Channel update: " ~ u.server ~ " " ~ u.channel ~ " " ~ u.action, "INFO", "main");
                updateChannelList(u.server, u.channel, u.action);
                break;

            case IrcToGuiType.systemMessage:
                auto sysMsg = msg.systemMsg;
                logToTerminal("System message: " ~ sysMsg.text, "DEBUG", "main");

                string server = currentServer.length > 0 ? currentServer : "System";
                // Server messages use server name as key (not qualified)
                string bufferKey = server;

                if (!(server in serverBuffers))
                    serverBuffers[server] = null;
                if (!(bufferKey in serverBuffers[server]))
                    serverBuffers[server][bufferKey] = "";

                string formatted = formatSystemMessage(sysMsg.text);
                serverBuffers[server][bufferKey] ~= formatted;

                // Show in UI based on current context
                if (currentServer.length > 0)
                {
                    // If this message is for the current server, show it
                    if (server == currentServer)
                    {
                        chatArea.appendMessage(currentDisplay, formatted);
                        if (sysMsg.text == "Connected to " ~ currentServer)
                        {
                            statusLabel.setText(QString("Connected to " ~ currentServer));
                            logToTerminal("Statusbar updated to: Connected to " ~ currentServer, "INFO", "main");
                        }
                    }
                }
                else
                {
                    chatArea.appendMessage("System", formatted);
                }
                break;

            case IrcToGuiType.channelTopic:
                auto topicData = msg.topicData;
                logToTerminal("Channel topic: " ~ topicData.server ~ " " ~ topicData.channel, "DEBUG", "main");
                handleChannelTopic(topicData.server, topicData.channel, topicData.topic);
                break;
        }
    }

    void updateChannelList(string server, string channel, string action)
    {
        string bufferKey = server ~ ":" ~ channel;

        if (action == "join")
        {
            logToTerminal("Adding channel: " ~ channel ~ " to server: " ~ server, "INFO", "main");
            sidebar.addChannel(server, channel);

            // Initialize buffer for this channel using qualified key
            if (!(server in serverBuffers))
                serverBuffers[server] = null;
            if (!(bufferKey in serverBuffers[server]))
                serverBuffers[server][bufferKey] = "";

            if (autoSwitchToNewChannels)
            {
                currentDisplay = channel;
                currentServer = server;
                chatArea.setDisplay(channel);

                // Load the correct buffer using qualified key
                if (bufferKey in serverBuffers[server])
                {
                    chatArea.setContent(serverBuffers[server][bufferKey]);
                }
                logToTerminal("Auto-switched to channel: " ~ channel ~ " on server: " ~ server, "INFO", "main");
            }

            if (!displayHistory.canFind(channel))
                displayHistory ~= channel;

            if (server in channelTopics && channel in channelTopics[server])
            {
                string topic = channelTopics[server][channel];
                string formatted = formatSystemMessage("Topic: " ~ topic);
                if (server == currentServer && channel == currentDisplay)
                {
                    chatArea.appendMessage(channel, formatted);
                }
                if (bufferKey in serverBuffers[server])
                {
                    serverBuffers[server][bufferKey] ~= formatted;
                }
            }
        }
        else if (action == "part")
        {
            logToTerminal("Removing channel: " ~ channel ~ " from server: " ~ server, "INFO", "main");
            sidebar.removeChannel(server, channel);

            // Remove from history
            size_t idx = -1;
            for (size_t i = 0; i < displayHistory.length; i++)
            {
                if (displayHistory[i] == channel)
                {
                    idx = i;
                    break;
                }
            }
            if (idx != -1)
                displayHistory = displayHistory[0 .. idx] ~ displayHistory[idx + 1 .. $];

            if (currentDisplay == channel && currentServer == server)
            {
                if (displayHistory.length > 0)
                    currentDisplay = displayHistory[$ - 1];
                else
                    currentDisplay = "System";

                chatArea.setDisplay(currentDisplay);

                // Load the new display's buffer
                if (currentDisplay == "System")
                {
                    if ("System" in serverBuffers && "System" in serverBuffers["System"])
                    {
                        chatArea.setContent(serverBuffers["System"]["System"]);
                    }
                }
                else if (currentDisplay == currentServer)
                {
                    // Switching to server buffer
                    if (currentServer in serverBuffers && currentServer in serverBuffers[currentServer])
                    {
                        chatArea.setContent(serverBuffers[currentServer][currentServer]);
                    }
                }
                else
                {
                    string newKey = currentServer ~ ":" ~ currentDisplay;
                    if (currentServer in serverBuffers && newKey in serverBuffers[currentServer])
                    {
                        chatArea.setContent(serverBuffers[currentServer][newKey]);
                    }
                }
                logToTerminal("Switched to: " ~ currentDisplay ~ " on server: " ~ currentServer, "INFO", "main");
            }

            if (server in channelTopics)
                channelTopics[server].remove(channel);
        }
    }

    void handleChannelTopic(string server, string channel, string topic)
    {
        if (!(server in channelTopics))
            channelTopics[server] = null;

        channelTopics[server][channel] = topic;

        string formatted = formatSystemMessage("Topic: " ~ topic);
        string bufferKey = server ~ ":" ~ channel;

        // Store in buffer
        if (server in serverBuffers && bufferKey in serverBuffers[server])
        {
            serverBuffers[server][bufferKey] ~= formatted;
            if (currentDisplay == channel && currentServer == server)
            {
                chatArea.appendMessage(channel, formatted);
            }
        }
    }

    void handleCommand(string text)
    {
        logToTerminal("Handling command: " ~ text, "INFO", "main");

        if (text.startsWith("/connect "))
        {
            auto server = text["/connect ".length .. $].strip();
            startConnection(server);
        }
        else if (text.startsWith("/join "))
        {
            auto channel = text["/join ".length .. $].strip();
            if (!channel.startsWith("#"))
                channel = "#" ~ channel;
            if (channel.length == 1)
            {
                appendSystemMessage("Usage: /join #channel");
                return;
            }
            appendSystemMessage("Joining " ~ channel);
            auto msg = GuiToIrcMessage(GuiToIrcMessage.Type.UpdateChannels, channel, "", "join");
            sendToIrcThread(currentServer, msg);
            updateChannelList(currentServer, channel, "join");
        }
        else if (text.startsWith("/part "))
        {
            auto channel = text["/part ".length .. $].strip();
            appendSystemMessage("Leaving " ~ channel);
            auto msg = GuiToIrcMessage(GuiToIrcMessage.Type.UpdateChannels, channel, "", "part");
            sendToIrcThread(currentServer, msg);
            updateChannelList(currentServer, channel, "part");
        }
        else if (text.startsWith("/whois "))
        {
            auto target = text["/whois ".length .. $].strip();
            if (currentServer.length > 0 && currentServer in serverThreads)
            {
                auto msg = GuiToIrcMessage(GuiToIrcMessage.Type.UpdateChannels, target, "", "whois");
                sendToIrcThread(currentServer, msg);
                string formatted = formatSystemMessage("WHOIS request sent for " ~ target);
                chatArea.appendMessage(currentDisplay, formatted);
            }
            else
            {
                appendSystemMessage("Not connected to a server.");
            }
        }
        else if (text.startsWith("/disconnect"))
        {
            disconnectFromServer();
        }
        else if (text.startsWith("/quit"))
        {
            disconnectAllServers();
            appendSystemMessage("Goodbye!");
            Thread.sleep(100.msecs);
            QApplication.quit();
        }
        else if (text.startsWith("/msg ") || text.startsWith("/query "))
        {
            auto rest = text["/msg ".length .. $].strip();
            auto spacePos = rest.indexOf(" ");
            if (spacePos != -1)
            {
                auto recipient = rest[0 .. spacePos].strip();
                auto message = rest[spacePos .. $].strip();
                auto msg = GuiToIrcMessage(GuiToIrcMessage.Type.Message, recipient, message, "");
                sendToIrcThread(currentServer, msg);
            }
            else
            {
                appendSystemMessage("Usage: /msg nick message");
            }
        }
        else if (text.startsWith("/me "))
        {
            if (currentDisplay.startsWith("#"))
            {
                auto action = text["/me ".length .. $];
                string actionMsg = "\x01ACTION " ~ action ~ "\x01";
                auto msg = GuiToIrcMessage(GuiToIrcMessage.Type.Message, currentDisplay, actionMsg, "");
                sendToIrcThread(currentServer, msg);
            }
            else
            {
                appendSystemMessage("/me can only be used in channels");
            }
        }
        else if (text.startsWith("/nick "))
        {
            auto newNick = text["/nick ".length .. $].strip();
            auto msg = GuiToIrcMessage(GuiToIrcMessage.Type.Message, "", "NICK " ~ newNick, "");
            sendToIrcThread(currentServer, msg);
            string formatted = formatSystemMessage("Changing nickname to: " ~ newNick);
            chatArea.appendMessage(currentServer, formatted);
        }
        else if (text.startsWith("/help"))
        {
            appendSystemMessage("Available commands:");
            appendSystemMessage("  /connect <server> - Connect to an IRC server");
            appendSystemMessage("  /join <#channel> - Join a channel");
            appendSystemMessage("  /part [channel] - Leave current or specified channel");
            appendSystemMessage("  /whois <nickname> - Get user information");
            appendSystemMessage("  /msg <nick> <message> - Send private message");
            appendSystemMessage("  /me <action> - Send action to channel");
            appendSystemMessage("  /nick <newnick> - Change nickname");
            appendSystemMessage("  /disconnect - Disconnect from current server");
            appendSystemMessage("  /quit - Quit the application");
            appendSystemMessage("  /help - Show this help");
        }
        else
        {
            string rawCommand = text[1 .. $];
            auto msg = GuiToIrcMessage(GuiToIrcMessage.Type.Message, "", rawCommand, "");
            sendToIrcThread(currentServer, msg);

            string formatted = formatSystemMessage(">>> " ~ rawCommand);
            if (currentDisplay.startsWith("#"))
            {
                chatArea.appendMessage(currentDisplay, formatted);
            }
            else
            {
                chatArea.appendMessage(currentServer, formatted);
            }
        }
    }

    string formatTimestampNow()
    {
        auto now = Clock.currTime();
        return "[" ~ format("%02d:%02d", now.hour, now.minute) ~ "]";
    }

    void appendSystemMessage(string message)
    {
        string formatted = formatSystemMessage(message);
        chatArea.appendMessage("System", formatted);

        // Also store in system buffer
        string server = "System";
        if (!(server in serverBuffers))
            serverBuffers[server] = null;
        if (!(server in serverBuffers[server]))
            serverBuffers[server][server] = "";
        serverBuffers[server][server] ~= formatted;
    }

    string getNickColor(string nickname)
    {
        if (!colorizeNicks)
            return isDarkTheme ? "#CCCCCC" : "#666666";

        if (nickname in nickColorCache)
            return nickColorCache[nickname];

        string normalized = nickname.strip().toLower();
        if (normalized.length == 0)
            normalized = "user";

        uint hash1 = 0;
        uint hash2 = 0x811c9dc5u;

        for (int i = 0; i < normalized.length; i++)
        {
            char c = normalized[i];
            uint pos = i + 1;
            hash1 = ((hash1 << 5) + hash1) + c * pos;
            hash2 ^= c * (pos * 31);
            hash2 *= 0x01000193u;
        }

        uint combined = hash1 ^ hash2;
        combined ^= combined >> 16;
        combined *= 0x85ebca6bu;
        combined ^= combined >> 13;
        combined *= 0xc2b2ae35u;
        combined ^= combined >> 16;

        float hue = cast(float)(combined % 360);
        hue = hue * 0.618033988749895f;
        hue = fmod(hue + 137.0f, 360.0f);

        string color;
        if (isDarkTheme)
        {
            float saturation = 0.85f;
            float lightness = 0.65f;
            uint varHash = (combined >> 8) & 0xFF;
            saturation += 0.1f * (cast(float) varHash / 255.0f);
            lightness += 0.1f * (cast(float)((combined >> 16) & 0xFF) / 255.0f);
            color = hslToHex(hue, saturation, lightness);
        }
        else
        {
            float saturation = 0.9f;
            float lightness = 0.45f;
            uint varHash = (combined >> 8) & 0xFF;
            saturation += 0.05f * (cast(float) varHash / 255.0f);
            lightness += 0.1f * (cast(float)((combined >> 16) & 0xFF) / 255.0f);
            color = hslToHex(hue, saturation, lightness);
        }

        nickColorCache[nickname] = color;
        return color;
    }

    string hslToHex(float h, float s, float l)
    {
        h = fmod(h, 360.0f);
        if (h < 0) h += 360.0f;
        s = s < 0.0f ? 0.0f : (s > 1.0f ? 1.0f : s);
        l = l < 0.0f ? 0.0f : (l > 1.0f ? 1.0f : l);

        float c = (1.0f - abs(2.0f * l - 1.0f)) * s;
        float x = c * (1.0f - abs(fmod(h / 60.0f, 2.0f) - 1.0f));
        float m = l - c / 2.0f;
        float r, g, b;

        if (h < 60) { r = c; g = x; b = 0; }
        else if (h < 120) { r = x; g = c; b = 0; }
        else if (h < 180) { r = 0; g = c; b = x; }
        else if (h < 240) { r = 0; g = x; b = c; }
        else if (h < 300) { r = x; g = 0; b = c; }
        else { r = c; g = 0; b = x; }

        r += m; g += m; b += m;
        r = r < 0.0f ? 0.0f : (r > 1.0f ? 1.0f : r);
        g = g < 0.0f ? 0.0f : (g > 1.0f ? 1.0f : g);
        b = b < 0.0f ? 0.0f : (b > 1.0f ? 1.0f : b);

        int ri = cast(int)(r * 255);
        int gi = cast(int)(g * 255);
        int bi = cast(int)(b * 255);

        return "#" ~ format("%02X%02X%02X", ri, gi, bi);
    }

    string getModeSymbolColor(char modeSymbol)
    {
        switch (modeSymbol)
        {
            case '@': return isDarkTheme ? "#FF4444" : "#D32F2F";
            case '%': return isDarkTheme ? "#FF9800" : "#F57C00";
            case '+': return isDarkTheme ? "#4CAF50" : "#388E3C";
            case '&': return isDarkTheme ? "#2196F3" : "#1976D2";
            case '~': return isDarkTheme ? "#9C27B0" : "#7B1FA2";
            default:  return isDarkTheme ? "#CCCCCC" : "#666666";
        }
    }

    string ircToHtml(string input)
    {
        import std.string;
        import std.array;
        string result;
        bool inColor = false;
        bool inBold = false;
        bool inUnderline = false;
        string currentFg, currentBg;

        for (size_t i = 0; i < input.length; i++)
        {
            char c = input[i];

            if (c == 3) // Color code
            {
                if (inColor) result ~= "</span>";

                // Parse color numbers
                string fg, bg;

                // Get foreground color (1-2 digits)
                if (i + 1 < input.length && input[i+1] >= '0' && input[i+1] <= '9')
                {
                    fg ~= input[++i];
                    if (i + 1 < input.length && input[i+1] >= '0' && input[i+1] <= '9')
                        fg ~= input[++i];
                }

                // Check for background color (after comma)
                if (i + 1 < input.length && input[i+1] == ',')
                {
                    i++; // skip comma
                    if (i + 1 < input.length && input[i+1] >= '0' && input[i+1] <= '9')
                    {
                        bg ~= input[++i];
                        if (i + 1 < input.length && input[i+1] >= '0' && input[i+1] <= '9')
                            bg ~= input[++i];
                    }
                }

                // Build style
                string style;
                if (fg.length > 0)
                {
                    int fgNum = to!int(fg);
                    style ~= "color: " ~ ircColorToHex(fgNum) ~ ";";
                }
                if (bg.length > 0)
                {
                    int bgNum = to!int(bg);
                    style ~= "background-color: " ~ ircColorToHex(bgNum) ~ ";";
                }

                if (style.length > 0)
                {
                    result ~= "<span style='" ~ style ~ "'>";
                    inColor = true;
                }
            }
            else if (c == 15) // Reset ALL formatting
            {
                if (inColor) result ~= "</span>";
                if (inBold) result ~= "</b>";
                if (inUnderline) result ~= "</u>";
                inColor = false;
                inBold = false;
                inUnderline = false;
                currentFg = currentBg = "";
            }
            else if (c == 2) // Bold
            {
                if (inBold)
                    result ~= "</b>";
                else
                    result ~= "<b>";
                inBold = !inBold;
            }
            else if (c == 22) // Reverse? handle appropriately
            {
                // Skip or handle
            }
            else if (c == 31) // Underline
            {
                if (inUnderline)
                    result ~= "</u>";
                else
                    result ~= "<u>";
                inUnderline = !inUnderline;
            }
            else
            {
                result ~= c;
            }
        }

        // Close any remaining tags at end
        if (inColor) result ~= "</span>";
        if (inBold) result ~= "</b>";
        if (inUnderline) result ~= "</u>";

        return result;
    }

    string ircColorToHex(int color)
    {
        // Standard IRC colors (0-15)
        switch (color)
        {
            case 0: return "#FFFFFF"; // White
            case 1: return "#000000"; // Black
            case 2: return "#00007F"; // Blue
            case 3: return "#009300"; // Green
            case 4: return "#FF0000"; // Red
            case 5: return "#7F0000"; // Brown
            case 6: return "#9C009C"; // Purple
            case 7: return "#FC7F00"; // Orange
            case 8: return "#FFFF00"; // Yellow
            case 9: return "#00FC00"; // Light Green
            case 10: return "#009393"; // Cyan
            case 11: return "#00FFFF"; // Light Cyan
            case 12: return "#0000FC"; // Light Blue
            case 13: return "#FF00FF"; // Pink
            case 14: return "#7F7F7F"; // Grey
            case 15: return "#D2D2D2"; // Light Grey
            default: return "#000000";
        }
    }

    string formatChatMessage(string timestamp, string prefix, string nick, string type, string message, string display)
    {
        import std.string : replace;

        // First escape any HTML in the message
        string escapedMsg = message
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;")
            .replace("'", "&#39;");

        // Convert IRC color codes to HTML
        escapedMsg = ircToHtml(escapedMsg);

        string result = timestamp ~ " ";

        char modeSymbol = '\0';
        string baseNick = nick;

        if (nick.length > 0 && (nick[0] == '@' || nick[0] == '+' || nick[0] == '%' || nick[0] == '&' || nick[0] == '~'))
        {
            modeSymbol = nick[0];
            baseNick = nick[1 .. $];
        }

        // Colorize mentioned nicks in channel messages (e.g., "nick: message")
        if (colorizeNicks && display.startsWith("#")) {
            foreach (nickname, color; nickColorCache) {
                // Skip the sender's own nick
                if (nickname == baseNick) continue;

                // Handle "nick:" format
                string mention = nickname ~ ":";
                if (escapedMsg.canFind(mention)) {
                    string colored = "<span style='color: " ~ color ~ "; font-weight: bold;'>" ~ nickname ~ "</span>:";
                    escapedMsg = escapedMsg.replace(mention, colored);
                }

                // Handle "nick," format
                mention = nickname ~ ",";
                if (escapedMsg.canFind(mention)) {
                    string colored = "<span style='color: " ~ color ~ "; font-weight: bold;'>" ~ nickname ~ "</span>,";
                    escapedMsg = escapedMsg.replace(mention, colored);
                }
            }
        }

        switch (type)
        {
            case "message":
                if (nick.length > 0)
                {
                    if (modeSymbol != '\0')
                    {
                        string color = getModeSymbolColor(modeSymbol);
                        result ~= "<span style='color: " ~ color ~ "; font-weight: bold;'>" ~ [modeSymbol].idup ~ "</span>";
                    }

                    if (colorizeNicks)
                    {
                        string color = getNickColor(baseNick);
                        result ~= "<span style='color: " ~ color ~ "; font-weight: bold;'>" ~ baseNick ~ "</span>";
                    }
                    else
                    {
                        result ~= baseNick;
                    }

                    result ~= ": " ~ escapedMsg ~ "<br>";
                }
                else
                {
                    result ~= escapedMsg ~ "<br>";
                }
                break;

            case "action":
                result ~= "* ";
                if (nick.length > 0)
                {
                    if (modeSymbol != '\0')
                    {
                        string color = getModeSymbolColor(modeSymbol);
                        result ~= "<span style='color: " ~ color ~ "; font-weight: bold;'>" ~ [modeSymbol].idup ~ "</span>";
                    }

                    if (colorizeNicks)
                    {
                        string color = getNickColor(baseNick);
                        result ~= "<span style='color: " ~ color ~ "; font-weight: bold;'>" ~ baseNick ~ "</span>";
                    }
                    else
                    {
                        result ~= baseNick;
                    }

                    result ~= " " ~ escapedMsg ~ "<br>";
                }
                else
                {
                    result ~= " " ~ escapedMsg ~ "<br>";
                }
                break;

            case "notice":
                result ~= "-";
                if (nick.length > 0)
                {
                    if (modeSymbol != '\0')
                    {
                        string color = getModeSymbolColor(modeSymbol);
                        result ~= "<span style='color: " ~ color ~ "; font-weight: bold;'>" ~ [modeSymbol].idup ~ "</span>";
                    }

                    if (colorizeNicks)
                    {
                        string color = getNickColor(baseNick);
                        result ~= "<span style='color: " ~ color ~ "; font-weight: bold;'>" ~ baseNick ~ "</span>";
                    }
                    else
                    {
                        result ~= baseNick;
                    }

                    result ~= "- " ~ escapedMsg ~ "<br>";
                }
                else
                {
                    result ~= "- " ~ escapedMsg ~ "<br>";
                }
                break;

            case "join": case "part": case "quit": case "kick": case "nick":
                if (nick.length > 0)
                {
                    if (modeSymbol != '\0')
                    {
                        string color = getModeSymbolColor(modeSymbol);
                        result ~= "<span style='color: " ~ color ~ "; font-weight: bold;'>" ~ [modeSymbol].idup ~ "</span>";
                    }

                    if (colorizeNicks)
                    {
                        string color = getNickColor(baseNick);
                        result ~= "<span style='color: " ~ color ~ "; font-weight: bold;'>" ~ baseNick ~ "</span>";
                    }
                    else
                    {
                        result ~= baseNick;
                    }

                    result ~= " " ~ escapedMsg ~ "<br>";
                }
                else
                {
                    result ~= escapedMsg ~ "<br>";
                }
                break;

            default:
                if (nick.length > 0)
                {
                    if (colorizeNicks)
                    {
                        string color = getNickColor(baseNick);
                        result ~= "<span style='color: " ~ color ~ "; font-weight: bold;'>" ~ baseNick ~ "</span>";
                    }
                    else
                    {
                        result ~= baseNick;
                    }
                    result ~= ": " ~ escapedMsg ~ "<br>";
                }
                else
                {
                    result ~= escapedMsg ~ "<br>";
                }
                break;
        }

        return result;
    }

    string formatSystemMessage(string message)
    {
        string color = isDarkTheme ? "#AAAAAA" : "#555555";
        return "<span style='color: " ~ color ~ ";'>" ~ message ~ "</span><br>";
    }

    void appendWelcomeMessage()
    {
        appendSystemMessage("Welcome to D IRC Client!");
        appendSystemMessage("Type /connect <server> to connect to an IRC server");
        appendSystemMessage("Type /join #channel to join a channel");
        appendSystemMessage("Type /whois <nickname> for user information");
        appendSystemMessage("Type /help for more commands");
    }
}
