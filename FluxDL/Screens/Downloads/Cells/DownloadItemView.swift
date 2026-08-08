//
//  DownloadItemView.swift
//  FluxDL
//
//  Created by FluxDL on 08/08/2026.
//

import MvvmFoundation
import SwiftUI
import UIKit

struct DownloadItemView: MvvmSwiftUICellProtocol {
    typealias ViewModel = DownloadItemViewModel

    @ObservedObject var viewModel: ViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: viewModel.iconName)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.filename)
                    .foregroundStyle(.primary)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 0) {
                    Text(viewModel.detailText)
                    Text(viewModel.statusText)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(.secondary)
                .font(.footnote)
                if viewModel.canPause || viewModel.canResume {
                    ProgressView(value: viewModel.progress)
                }
            }
        }
        .padding(.vertical, 2)
        .swipeActions {
            Button(role: .destructive) {
                viewModel.deleteAction?()
            } label: {
                Image(systemName: "trash")
            }

            if viewModel.canResume {
                Button {
                    viewModel.resumeAction?()
                } label: {
                    Image(systemName: "play.fill")
                }
            }

            if viewModel.canPause {
                Button {
                    viewModel.pauseAction?()
                } label: {
                    Image(systemName: "pause.fill")
                }
            }
        }
    }

    static let registration: UICollectionView.CellRegistration<UICollectionViewListCell, ViewModel> = .init { cell, _, itemIdentifier in
        cell.contentConfiguration = UIHostingConfiguration {
            Self(viewModel: itemIdentifier)
        }

        var config: UIBackgroundConfiguration
        if #available(iOS 18.0, visionOS 2.0, *) {
            config = .listCell()
        } else {
            config = .listPlainCell()
        }

        config.backgroundColorTransformer = .init { color in
            guard !cell.isHighlighted, !cell.isSelected
            else { return color }

            return .clear
        }
        cell.backgroundConfiguration = config
        cell.accessories = []
    }
}