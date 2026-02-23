module chatarea;

import qt.core.object;
import qt.core.string;
import qt.gui.textcursor;
import qt.widgets.textedit;
import qt.widgets.widget;
import qt.widgets.ui;
import qt.helpers;

struct ChatAreaUI
{
    mixin(generateUICode(import("chatarea.ui"), "chatarea"));
}

class ChatArea : QWidget
{
    mixin(Q_OBJECT_D);

private:
    ChatAreaUI* ui;
    string currentDisplay;
    string[string] displayBuffers;

public:
    this(QWidget parent = null)
    {
        import core.stdcpp.new_;
        super(parent);
        ui = cpp_new!ChatAreaUI();
        ui.setupUi(this);
    }

    ~this()
    {
        import core.stdcpp.new_;
        cpp_delete(ui);
    }

    void setDisplay(string display)
    {
        currentDisplay = display;
        if (display in displayBuffers)
        {
            ui.chatView.setHtml(QString(displayBuffers[display]));
        }
        else
        {
            ui.chatView.setHtml(QString(""));
        }
	scrollToEnd();
    }

    void appendMessage(string display, string html)
    {
	if (!(display in displayBuffers))
	    displayBuffers[display] = "";

	displayBuffers[display] ~= html;

	if (display == currentDisplay)
	{
	    QTextCursor cursor = ui.chatView.textCursor();
	    cursor.movePosition(
		QTextCursor.MoveOperation.End,
		QTextCursor.MoveMode.MoveAnchor
	    );
	    ui.chatView.setTextCursor(cursor);
	    ui.chatView.insertHtml(QString(html));
	    scrollToEnd();
	}
    }

    void setContent(string content)
    {
        ui.chatView.setHtml(QString(content));
        scrollToEnd();
    }

    void scrollToEnd()
    {
        auto cursor = ui.chatView.textCursor();
        cursor.movePosition(
            QTextCursor.MoveOperation.End,
            QTextCursor.MoveMode.MoveAnchor
        );
        ui.chatView.setTextCursor(cursor);
    }
}
