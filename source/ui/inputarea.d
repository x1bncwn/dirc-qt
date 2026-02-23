module inputarea;

import qt.core.object;
import qt.core.string;
import qt.widgets.lineedit;
import qt.widgets.pushbutton;
import qt.widgets.widget;
import qt.widgets.ui;
import qt.helpers;

struct InputAreaUI
{
    mixin(generateUICode(import("inputarea.ui"), "inputarea"));
}

class InputArea : QWidget
{
    mixin(Q_OBJECT_D);

private:
    InputAreaUI* ui;

public:
    this(QWidget parent = null)
    {
        import core.stdcpp.new_;
        super(parent);
        ui = cpp_new!InputAreaUI();
        ui.setupUi(this);

        connect(ui.inputLine.signal!"returnPressed", this.slot!"onReturnPressed");
        connect(ui.sendButton.signal!"clicked", this.slot!"onSendClicked");
    }

    ~this()
    {
        import core.stdcpp.new_;
        cpp_delete(ui);
    }

    QString getText()
    {
        return ui.inputLine.text();
    }

    void clear()
    {
        ui.inputLine.clear();
    }

/+ signals +/ public:
    @QSignal final void sendMessage(QString text) {mixin(Q_SIGNAL_IMPL_D);}

private /+ slots +/:
    @QSlot final void onReturnPressed()
    {
        sendMessage(ui.inputLine.text());
    }

    @QSlot final void onSendClicked()
    {
        sendMessage(ui.inputLine.text());
    }
}
