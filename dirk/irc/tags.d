module irc.tags;

import std.string : indexOf;
import std.conv : to;

/**
 * IRCv3 message tags container
 */
struct IrcTags
{
    string[string] tags; /// tag name -> value (empty string for valueless tags)

    /**
     * Check if a tag exists
     */
    bool hasTag(string name) const
    {
        return (name in tags) !is null;
    }

    /**
     * Get tag value (returns null if tag doesn't exist)
     */
    const(string)* opBinary(string op : "in")(string name) const
    {
        return name in tags;
    }

    /**
     * Get tag value as string (empty string if not found)
     */
    string get(string name) const
    {
        auto p = name in tags;
        return p ? *p : "";
    }

    /**
     * Get tag value parsed as type T
     */
    T getAs(T)(string name) const
    {
        auto p = name in tags;
        return p ? to!T(*p) : T.init;
    }
}

/**
 * Parse IRCv3 message tags from a raw message
 *
 * Params:
 *   raw = raw message line (may start with @tags)
 *   tags = output tags structure
 *   rest = remaining message after tags (including prefix/command)
 *
 * Returns:
 *   true if tags were parsed, false if no tags
 */
@safe bool parseTags(const(char)[] raw, out IrcTags tags, out const(char)[] rest)
{
    if (raw.length == 0 || raw[0] != '@')
    {
        rest = raw;
        return false;
    }

    // Find end of tags (space after tags)
    size_t spacePos = raw.indexOf(' ');
    if (spacePos == -1)
    {
        rest = raw;
        return false;
    }

    auto tagSection = raw[1 .. spacePos]; // Skip the @
    rest = raw[spacePos + 1 .. $];

    // Parse individual tags (tag=value;nexttag=value;...)
    size_t pos = 0;
    while (pos < tagSection.length)
    {
        size_t eqPos = tagSection.indexOf('=', pos);
        size_t semiPos = tagSection.indexOf(';', pos);

        string name;
        string value;

        if (eqPos != -1 && (semiPos == -1 || eqPos < semiPos))
        {
            // Tag has value
            name = tagSection[pos .. eqPos].idup;

            size_t valueEnd = semiPos != -1 ? semiPos : tagSection.length;
            value = tagSection[eqPos + 1 .. valueEnd].idup;

            pos = valueEnd + (semiPos != -1 ? 1 : 0);
        }
        else if (semiPos != -1)
        {
            // Tag without value (just name)
            name = tagSection[pos .. semiPos].idup;
            value = "";
            pos = semiPos + 1;
        }
        else
        {
            // Last tag without value
            name = tagSection[pos .. $].idup;
            value = "";
            pos = tagSection.length;
        }

        // Unescape tag values (if needed)
        // TODO: Add unescaping for \: \s \r \n \\

        tags.tags[name] = value;
    }

    return true;
}

unittest
{
    IrcTags tags;
    const(char)[] rest;

    assert(parseTags("@tag1=value1;tag2;tag3=value3 PRIVMSG #channel :hello", tags, rest));
    assert(tags.get("tag1") == "value1");
    assert(tags.get("tag2") == "");
    assert(tags.get("tag3") == "value3");
    assert(rest == "PRIVMSG #channel :hello");

    assert(!parseTags("PRIVMSG #channel :hello", tags, rest));
    assert(rest == "PRIVMSG #channel :hello");
}
