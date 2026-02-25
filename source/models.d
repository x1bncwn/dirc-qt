module models;

import std.stdio;
import std.conv;
import std.string;
import std.array;
import std.algorithm;

immutable string defaultChannel = "#dirc-test";
immutable string defaultServer = "irc.libera.chat";
immutable ushort defaultPort = 6697;
immutable string defaultNick = "x2bncwn";

/// Types of messages sent from the IRC thread to the GUI thread
enum IrcToGuiType {
    chatMessage,
    channelUpdate,
    systemMessage,
    channelTopic
}

/// Structured chat message with separate raw nick and prefix
struct ChatMessage {
    string server;
    string channel;
    string timestamp;
    string rawNick;
    string prefix;
    string messageType;
    string body;
}

/// Channel join/part/failed update
struct ChannelUpdate {
    string server;
    string channel;
    string action;
}

/// Channel topic update
struct ChannelTopic {
    string server;
    string channel;
    string topic;
}

/// System message types
enum SystemMsgType {
    generic,
    motd,
    whois,
    error,
    info,
    warning
}

/// System message struct for generic or typed messages
struct SystemMessage {
    SystemMsgType msgType = SystemMsgType.generic;
    string text;

    // Constructor for generic system messages
    this(string t) {
        this.text = t;
    }

    // Constructor for typed system messages
    this(SystemMsgType type, string t) {
        this.text = t;
        this.msgType = type;
    }
}

/// Union of all messages sent to GUI
struct IrcToGuiMessage {
    IrcToGuiType type;

    union {
        ChatMessage chat;
        ChannelUpdate channelUpdate;
        ChannelTopic topicData;
        SystemMessage systemMsg;
    }

    // Factory methods
    static IrcToGuiMessage fromChat(ChatMessage c) {
        IrcToGuiMessage m;
        m.type = IrcToGuiType.chatMessage;
        m.chat = c;
        return m;
    }

    static IrcToGuiMessage fromUpdate(ChannelUpdate u) {
        IrcToGuiMessage m;
        m.type = IrcToGuiType.channelUpdate;
        m.channelUpdate = u;
        return m;
    }

    static IrcToGuiMessage fromSystem(string text) {
        IrcToGuiMessage m;
        m.type = IrcToGuiType.systemMessage;
        m.systemMsg = SystemMessage(text);
        return m;
    }

    static IrcToGuiMessage fromSystem(string text, SystemMsgType msgType) {
        IrcToGuiMessage m;
        m.type = IrcToGuiType.systemMessage;
        m.systemMsg = SystemMessage(msgType, text);
        return m;
    }

    static IrcToGuiMessage fromTopic(ChannelTopic t) {
        IrcToGuiMessage m;
        m.type = IrcToGuiType.channelTopic;
        m.topicData = t;
        return m;
    }
}

/// Messages from GUI to IRC thread
struct GuiToIrcMessage {
    enum Type {
        Message,
        UpdateChannels,
        ChannelTopic
    }

    Type type;
    string channel;
    string text;
    string action;
}
