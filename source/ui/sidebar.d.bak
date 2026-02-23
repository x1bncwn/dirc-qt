module sidebar;

import qt.core.object;
import qt.core.string;
import qt.core.variant;
import qt.core.namespace;
import qt.widgets.treewidget;
import qt.widgets.widget;
import qt.widgets.ui;
import qt.helpers;
import core.stdcpp.new_;

struct SidebarUI
{
    mixin(generateUICode(import("sidebar.ui"), "sidebar"));
}

class Sidebar : QWidget
{
    mixin(Q_OBJECT_D);
    
private:
    SidebarUI* ui;
    
public:
    this(QWidget parent = null)
    {
        import core.stdcpp.new_;
        super(parent);
        ui = cpp_new!SidebarUI();
        ui.setupUi(this);
        
        // Connect internal signal to our public signal
        connect(ui.channelTree.signal!"itemClicked", this.slot!"onItemClicked");
    }
    
    ~this()
    {
        import core.stdcpp.new_;
        cpp_delete(ui);
    }
    
    void addServer(string server)
    {
        import core.stdcpp.new_;
        auto item = cpp_new!QTreeWidgetItem();
        item.setText(0, QString(server));
        item.setData(0, qt.core.namespace.ItemDataRole.UserRole, QVariant(QString("server")));
        ui.channelTree.addTopLevelItem(item);
        ui.channelTree.expandItem(item);
    }
    
    void addChannel(string server, string channel)
    {
        import core.stdcpp.new_;
        for (int i = 0; i < ui.channelTree.topLevelItemCount(); i++)
        {
            auto serverItem = ui.channelTree.topLevelItem(i);
            auto serverData = serverItem.text(0).toUtf8().constData();
            string serverName = serverData[0 .. serverItem.text(0).toUtf8().length()].idup;
            
            if (serverName == server)
            {
                auto item = cpp_new!QTreeWidgetItem();
                item.setText(0, QString(channel));
                item.setData(0, qt.core.namespace.ItemDataRole.UserRole, QVariant(QString("channel")));
                serverItem.addChild(item);
                ui.channelTree.expandItem(serverItem);
                break;
            }
        }
    }
    
    void removeChannel(string server, string channel)
    {
        for (int i = 0; i < ui.channelTree.topLevelItemCount(); i++)
        {
            auto serverItem = ui.channelTree.topLevelItem(i);
            auto serverData = serverItem.text(0).toUtf8().constData();
            string serverName = serverData[0 .. serverItem.text(0).toUtf8().length()].idup;
            
            if (serverName == server)
            {
                for (int j = 0; j < serverItem.childCount(); j++)
                {
                    auto child = serverItem.child(j);
                    auto childData = child.text(0).toUtf8().constData();
                    string childName = childData[0 .. child.text(0).toUtf8().length()].idup;
                    
                    if (childName == channel)
                    {
                        serverItem.takeChild(j);
                        return;
                    }
                }
            }
        }
    }
    
    void removeServer(string server)
    {
        for (int i = 0; i < ui.channelTree.topLevelItemCount(); i++)
        {
            auto serverItem = ui.channelTree.topLevelItem(i);
            auto serverData = serverItem.text(0).toUtf8().constData();
            string serverName = serverData[0 .. serverItem.text(0).toUtf8().length()].idup;
            
            if (serverName == server)
            {
                ui.channelTree.takeTopLevelItem(i);
                return;
            }
        }
    }
    
    void clear()
    {
        ui.channelTree.clear();
    }

/+ signals +/ public:
    @QSignal final void itemClicked(QTreeWidgetItem item, int column) {mixin(Q_SIGNAL_IMPL_D);}

private /+ slots +/:
    @QSlot final void onItemClicked(QTreeWidgetItem item, int column)
    {
        itemClicked(item, column);
    }
}
