module main;

import core.runtime;
import qt.core.coreapplication;
import qt.widgets.application;
import mainwindow;

int main()
{
    scope a = new QApplication(Runtime.cArgs.argc, Runtime.cArgs.argv);
    scope window = new MainWindow;
    window.show();

    return a.exec();
}
