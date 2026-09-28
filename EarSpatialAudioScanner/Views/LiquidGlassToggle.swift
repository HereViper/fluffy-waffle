import SwiftUI
import UIKit

public struct LiquidGlassToggle: View {
    @Binding public var isOn: Bool
    
    @State private var dragOffset: CGFloat = 0.0
    @State private var isDragging: Bool = false
    
    private let trackWidth: CGFloat = 52.0
    private let trackHeight: CGFloat = 31.0
    private let thumbSize: CGFloat = 27.0
    private let padding: CGFloat = 2.0
    
    public init(isOn: Binding<Bool>) {
        self._isOn = isOn
    }
    
    private var travelDistance: CGFloat {
        trackWidth - thumbSize - (padding * 2.0)
    }
    
    private var currentThumbOffset: CGFloat {
        if isDragging {
            let base: CGFloat = isOn ? travelDistance : 0.0
            let raw = base + dragOffset
            return min(max(raw, 0.0), travelDistance)
        } else {
            return isOn ? travelDistance : 0.0
        }
    }
    
    public var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(trackBackground)
                .frame(width: trackWidth, height: trackHeight)
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
            
            thumbView
                .offset(x: padding + currentThumbOffset)
                .animation(
                    .spring(response: 0.32, dampingFraction: 0.72),
                    value: isOn
                )
        }
        .frame(width: trackWidth, height: trackHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                isOn.toggle()
            }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    isDragging = true
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    isDragging = false
                    dragOffset = 0.0
                    let threshold = travelDistance / 2.0
                    let endX = (isOn ? travelDistance : 0.0) + value.translation.width
                    let targetState = endX > threshold
                    if targetState != isOn {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                        isOn = targetState
                    }
                }
        )
    }
    
    private var trackBackground: Color {
        isOn ? Color(red: 52/255, green: 199/255, blue: 89/255) : Color(white: 0.22)
    }
    
    private var thumbView: some View {
        ZStack {
            Capsule()
                .fill(thumbFillColor)
                .shadow(color: Color.black.opacity(0.22), radius: 3, x: 0, y: 1.5)
            
            LiquidGlassRefractionMeniscus(isOn: isOn)
        }
        .frame(
            width: isDragging ? thumbSize + 4.0 : thumbSize,
            height: thumbSize
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isDragging)
    }
    
    private var thumbFillColor: Color {
        if isOn {
            return Color(red: 46/255, green: 190/255, blue: 80/255)
        } else {
            return Color(white: 0.38)
        }
    }
}

struct LiquidGlassRefractionMeniscus: View {
    let isOn: Bool
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: 3.2, lineCap: .round)
                )
                .padding(2)
                .mask(
                    GeometryReader { geo in
                        Rectangle()
                            .frame(
                                width: geo.size.width * 0.72,
                                height: geo.size.height
                            )
                            .offset(x: isOn ? geo.size.width * 0.28 : 0)
                    }
                )
            
            Circle()
                .fill(Color.white.opacity(0.18))
                .blur(radius: 2)
                .padding(3)
        }
    }
}
