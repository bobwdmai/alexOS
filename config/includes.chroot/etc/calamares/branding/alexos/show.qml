import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation {
    id: presentation

    Timer {
        interval: 20000
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    Slide {
        Image {
            id: welcomeImage
            source: "welcome.svg"
            width: 700
            height: 280
            fillMode: Image.PreserveAspectFit
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 18
        }

        Text {
            anchors.horizontalCenter: welcomeImage.horizontalCenter
            anchors.top: welcomeImage.bottom
            anchors.topMargin: 18
            width: 660
            text: qsTr("AlexOS is copying the live system, setting up your user, and preparing the bootloader.")
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.Center
            color: "#e0fbfc"
            font.pixelSize: 18
        }
    }
}
